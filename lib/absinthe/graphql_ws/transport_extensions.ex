defmodule Absinthe.GraphqlWS.TransportExtensions do
  @moduledoc """
  Extensions to the base GraphQL-WS transport for @defer and @stream support.
  
  This module enhances the existing transport with incremental delivery capabilities,
  detecting and handling operations that use @defer or @stream directives.
  """
  
  alias Absinthe.GraphqlWS.{Transport, Message}
  alias Absinthe.GraphqlWS.Incremental
  alias Absinthe.Phase.Document.Execution.StreamingResolution
  
  require Logger
  
  @doc """
  Enhanced subscribe handler that detects and handles @defer/@stream directives.
  
  This function wraps the standard subscribe handler to add incremental delivery support.
  """
  def handle_subscribe_with_streaming(payload, id, socket) do
    with {:ok, query} <- parse_query(payload),
         {:ok, has_streaming} <- detect_streaming_directives(query) do
      
      if has_streaming do
        handle_streaming_operation(payload, id, socket)
      else
        # Fallback to standard subscribe handling
        Transport.handle_subscribe(payload, id, socket)
      end
    else
      {:error, reason} ->
        Logger.error("Failed to parse query for streaming detection: #{inspect(reason)}")
        Transport.handle_subscribe(payload, id, socket)
    end
  end
  
  @doc """
  Process messages that may contain streaming operations.
  
  This can be used to wrap the existing handle_inbound function.
  """
  def handle_inbound_with_streaming(%{"id" => id, "type" => "subscribe", "payload" => payload}, socket) do
    handle_subscribe_with_streaming(payload, id, socket)
  end
  
  def handle_inbound_with_streaming(msg, socket) do
    # Delegate non-subscribe messages to standard handler
    Transport.handle_inbound(msg, socket)
  end
  
  @doc """
  Handle incremental responses received from streaming tasks.
  """
  def handle_incremental_response({:incremental_response, operation_id, response}, socket) do
    transport = Incremental.Transport
    
    socket = Map.put(socket, :current_operation_id, operation_id)
    transport.send_incremental(socket, response)
  end
  
  # Private functions
  
  defp parse_query(%{"query" => query}) when is_binary(query) do
    {:ok, query}
  end
  defp parse_query(_), do: {:error, :no_query}
  
  defp detect_streaming_directives(query) do
    # Simple detection - could be enhanced with proper AST parsing
    has_defer = String.contains?(query, "@defer")
    has_stream = String.contains?(query, "@stream")
    {:ok, has_defer or has_stream}
  end
  
  defp handle_streaming_operation(payload, id, socket) do
    # Extract query and variables
    query = Map.get(payload, "query", "")
    variables = Map.get(payload, "variables", %{})
    
    # Configure pipeline with streaming resolution
    opts = build_streaming_options(socket, id, variables)
    
    # Execute with streaming-aware pipeline
    case run_streaming_document(query, socket.absinthe.schema, opts) do
      {:ok, blueprint} ->
        # Set current operation ID for the transport
        socket = Map.put(socket, :current_operation_id, id)
        
        # Process through incremental transport
        transport = Incremental.Transport
        transport.process_streaming_operation(socket, id, blueprint)
        
      {:error, errors} ->
        {:push, {:text, Message.Error.new(id, errors)}, socket}
    end
  end
  
  defp build_streaming_options(socket, operation_id, variables) do
    base_opts = socket.absinthe.opts || []
    
    Keyword.merge(base_opts, [
      variables: variables,
      operation_id: operation_id,
      transport: Incremental.Transport,
      context: %{
        pubsub: socket.pubsub,
        operation_id: operation_id
      }
    ])
  end
  
  defp run_streaming_document(document, schema, opts) do
    pipeline = build_streaming_pipeline(schema, opts)
    
    case Absinthe.Pipeline.run(document, pipeline) do
      {:ok, %{result: result} = blueprint, _phases} ->
        # Check if streaming was actually used
        if streaming_enabled?(blueprint) do
          {:ok, blueprint}
        else
          # Return as normal result
          {:ok, result}
        end
        
      {:error, msg, _phases} ->
        {:error, msg}
    end
  end
  
  defp build_streaming_pipeline(schema, opts) do
    # Build a pipeline that includes the streaming resolution phase
    schema
    |> Absinthe.Pipeline.for_document(opts)
    |> replace_resolution_phase()
  end
  
  defp replace_resolution_phase(pipeline) do
    # Replace the standard resolution phase with streaming resolution
    Enum.map(pipeline, fn
      {Absinthe.Phase.Document.Execution.Resolution, opts} ->
        {StreamingResolution, opts}
        
      phase ->
        phase
    end)
  end
  
  defp streaming_enabled?(blueprint) do
    get_in(blueprint, [:execution, :incremental_delivery]) == true
  end
  
  @doc """
  Setup async handling for incremental responses.
  
  This spawns a task to handle the incremental delivery asynchronously.
  """
  def setup_incremental_handler(socket, operation_id, blueprint) do
    streaming_context = get_streaming_context(blueprint)
    
    if streaming_context do
      Task.async(fn ->
        process_incremental_tasks(socket, operation_id, streaming_context)
      end)
    end
    
    {:ok, socket}
  end
  
  defp process_incremental_tasks(socket, operation_id, streaming_context) do
    # Process deferred fragments
    Enum.each(streaming_context.deferred_tasks || [], fn task ->
      Process.sleep(1) # Small delay to prevent overwhelming the client
      
      result = task.execute.()
      send(socket.transport_pid, {:incremental_response, operation_id, result})
    end)
    
    # Process streamed fields
    Enum.each(streaming_context.stream_tasks || [], fn task ->
      Process.sleep(1)
      
      result = task.execute.()
      send(socket.transport_pid, {:incremental_response, operation_id, result})
    end)
  end
  
  defp get_streaming_context(blueprint) do
    get_in(blueprint, [:execution, :context, :__streaming__])
  end
end
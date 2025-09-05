defmodule Absinthe.GraphqlWS.Incremental.Transport do
  @moduledoc """
  Incremental delivery support for the graphql-ws protocol.
  
  Implements @defer and @stream directives over the graphql-ws WebSocket protocol,
  sending incremental payloads through Next messages while maintaining protocol compliance.
  """
  
  use Absinthe.Incremental.Transport
  
  alias Absinthe.GraphqlWS.Message
  alias Absinthe.Incremental.Response
  
  require Logger
  
  @impl true
  def init(socket, options) do
    # Track active streaming operations
    socket = socket
    |> Map.put(:streaming_operations, %{})
    |> Map.put(:incremental_options, options)
    
    {:ok, socket}
  end
  
  @impl true
  def send_initial(%{current_operation_id: operation_id} = socket, response) do
    # Send initial Next message with data and pending information
    message = build_initial_message(operation_id, response)
    
    # Track this as an active streaming operation
    socket = put_in(
      socket.streaming_operations[operation_id],
      %{
        pending: Map.get(response, :pending, []),
        has_next: Map.get(response, :hasNext, false),
        completed_count: 0,
        total_count: length(Map.get(response, :pending, []))
      }
    )
    
    push_message(socket, message)
    {:ok, socket}
  end
  
  @impl true
  def send_incremental(%{current_operation_id: operation_id} = socket, response) do
    # Send incremental Next message
    message = build_incremental_message(operation_id, response)
    
    # Update streaming operation state
    socket = update_streaming_state(socket, operation_id, response)
    
    push_message(socket, message)
    
    # Check if we should send complete
    if should_complete?(socket, operation_id) do
      complete(socket)
    else
      {:ok, socket}
    end
  end
  
  @impl true
  def complete(%{current_operation_id: operation_id} = socket) do
    # Send Complete message to indicate end of stream
    message = Message.Complete.new(operation_id)
    
    # Clean up streaming operation tracking
    socket = update_in(
      socket.streaming_operations,
      &Map.delete(&1, operation_id)
    )
    
    push_message(socket, message)
    :ok
  end
  
  @impl true
  def handle_error(socket, error) do
    operation_id = socket.current_operation_id
    
    # Send error through Next message as per graphql-ws spec
    error_response = format_error_response(error)
    message = Message.Error.new(operation_id, error_response)
    
    push_message(socket, message)
    
    # Clean up if this was a fatal error
    if fatal_error?(error) do
      complete(socket)
    else
      {:ok, socket}
    end
  end
  
  @doc """
  Handle subscription with incremental delivery.
  
  Subscriptions can also use @defer and @stream within their selection sets.
  """
  def handle_subscription_incremental(socket, subscription_id, incremental_response) do
    # For subscriptions, we send incremental updates as part of the subscription stream
    message = build_subscription_incremental_message(subscription_id, incremental_response)
    push_message(socket, message)
    {:ok, socket}
  end
  
  @doc """
  Process an operation that contains @defer or @stream directives.
  """
  def process_streaming_operation(socket, operation_id, blueprint) do
    socket = Map.put(socket, :current_operation_id, operation_id)
    
    # Use the base transport's streaming handler
    handle_streaming_response(socket, blueprint, [])
  end
  
  # Private functions
  
  defp build_initial_message(operation_id, response) do
    # Format the initial payload according to graphql-ws spec
    # The response already contains data, pending, and hasNext
    payload = response
    
    Message.Next.new(operation_id, payload)
  end
  
  defp build_incremental_message(operation_id, response) do
    # Format incremental payload
    # Keep the incremental structure for clarity
    payload = response
    
    Message.Next.new(operation_id, payload)
  end
  
  defp build_subscription_incremental_message(subscription_id, response) do
    # Wrap incremental response in subscription payload
    payload = %{
      subscription: response
    }
    
    Message.Next.new(subscription_id, payload)
  end
  
  defp push_message(socket, message) do
    # Send the message through the WebSocket
    case socket do
      %{transport_pid: pid} when is_pid(pid) ->
        send(pid, {:push, {:text, message}})
        
      _ ->
        # Direct push for Phoenix.Socket
        {:push, {:text, message}, socket}
    end
  end
  
  defp update_streaming_state(socket, operation_id, response) do
    has_next = Map.get(response, :hasNext, false)
    completed = Map.get(response, :completed, [])
    
    update_in(
      socket.streaming_operations[operation_id],
      fn state ->
        state
        |> Map.put(:has_next, has_next)
        |> Map.update(:completed_count, length(completed), &(&1 + length(completed)))
      end
    )
  end
  
  defp should_complete?(socket, operation_id) do
    case socket.streaming_operations[operation_id] do
      %{has_next: false} -> true
      %{completed_count: completed, total_count: total} when completed >= total -> true
      _ -> false
    end
  end
  
  defp format_error_response(error) when is_binary(error) do
    [%{message: error}]
  end
  
  defp format_error_response(error) when is_map(error) do
    [error]
  end
  
  defp format_error_response(errors) when is_list(errors) do
    errors
  end
  
  defp format_error_response(error) do
    [%{message: inspect(error)}]
  end
  
  defp fatal_error?(error) do
    # Determine if an error should terminate the stream
    case error do
      {:timeout, _} -> true
      {:error, :max_complexity_exceeded} -> true
      _ -> false
    end
  end
end
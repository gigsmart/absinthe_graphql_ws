defmodule Absinthe.GraphqlWS.Transport do
  @moduledoc """
  Handles messages coming into the socket from clients (implemented in `handle_in/2`)
  as well as messages coming from within Elixir/Absinthe (implemented in `handle_info/2`).

  If the optional `c:Absinthe.GraphqlWS.Socket.handle_message/2` callback is implemented on
  the socket, then messages that are not specifically caught by `handle_info/2` in this
  module will be passed through to `c:Absinthe.GraphqlWS.Socket.handle_message/2`.

  **Note:** This module is not intended for use by individuals integrating this library into
  their codebase, but is documented to help understand the intentions of the code.
  """

  alias Absinthe.GraphqlWS.{Message, Socket, Util}
  alias Phoenix.Socket.Broadcast
  require Logger

  @ping "ping"
  @pong "pong"

  @type control :: Socket.control()
  @type reply_inbound() :: Socket.reply_inbound()
  @type reply_message() :: Socket.reply_message()
  @type socket() :: Socket.t()

  defmacrop debug(msg), do: quote(do: Logger.debug("[graph-socket@#{inspect(self())}] #{unquote(msg)}"))
  defmacrop warn(msg), do: quote(do: Logger.warning("[graph-socket@#{inspect(self())}] #{unquote(msg)}", []))

  @doc """
  Generally this will only receive `:pong` messages in response to our keepalive
  ping messages. Client-side websocket libraries handle these control frames
  automatically in order to adhere to the spec, so unless a customer is writing their
  own low-level websocket it should be handled for them.
  """
  @spec handle_control({term(), opcode: control()}, socket()) :: reply_inbound()
  def handle_control({_, opcode: :ping}, socket), do: {:reply, :ok, {:pong, @pong}, socket}
  def handle_control({_, opcode: :pong}, socket), do: {:ok, socket}

  def handle_control(message, state) do
    warn("unhandled control frame #{inspect(message)}")
    {:ok, state}
  end

  @doc """
  Receive messages from clients. We expect all incoming messages to be JSON encoded
  text, so if something else comes in we blow up.
  """
  @spec handle_in({binary(), [opcode: :text]}, socket()) :: reply_inbound()
  def handle_in({text, [opcode: :text]}, socket) do
    Util.json_library().decode(text)
    |> case do
      {:ok, json} ->
        handle_inbound(json, socket)

      {:error, reason} ->
        warn("JSON parse error: #{inspect(reason)}")
        {:reply, :error, {:text, Message.Error.new("4400")}, socket}
    end
  end

  @doc """
  Receive messages from inside the house.

  * `:keepalive` - Regularly send messages with opcode of `0x09`, ie `:ping`. The `graphql-ws`
    library has a strong opinion that it does not want to implement client-side keepalive, so
    in order to keep the websocket from closing we need to send it messages.

  * `subscription:data` - After we subscribe to an Absinthe subscription, we may receive messages
    for the relevant subscription. The `graphql-ws` will have sent us an `id` along with the
    subscription query, so we need to map our internal topic back to that `id` in order for the
    client to figure out what to do with our message.

  * `:complete` - If we get a `query` or a `mutation` on the websocket, we're supposed to reply
    with a `Next` message followed by a `Complete` message. We follow through on the latter by
    putting a message on our process queue.

  * fallthrough - If `c:Absinthe.GraphqlWs.Socket.handle_message/2` is defined on the socket,
    then uncaught messages will be sent there.
  """
  @spec handle_info(term(), socket()) :: reply_message()
  def handle_info(:keepalive, socket) do
    Process.send_after(self(), :keepalive, socket.keepalive)
    {:push, {:ping, @ping}, socket}
  end

  def handle_info(%Broadcast{event: "subscription:data", payload: payload, topic: topic}, socket) do
    subscription_id = socket.subscriptions[topic]
    {:push, {:text, Message.Next.new(subscription_id, payload.result)}, socket}
  end

  # Handle query/mutation operations results from PubSub
  def handle_info(%Broadcast{event: "query:data", payload: payload}, socket) do
    %{id: id, result: result, context: context, topic: topic} = payload
    
    # Unsubscribe from the query topic to prevent memory leaks
    Phoenix.PubSub.unsubscribe(socket.pubsub, topic)
    
    case result do
      %{data: _} = reply ->
        queue_complete_message(id)
        socket = merge_opts(socket, context: context)
        {:push, {:text, Message.Next.new(id, reply)}, socket}

      %{errors: errors} ->
        socket = merge_opts(socket, context: context)
        {:push, {:text, Message.Error.new(id, errors)}, socket}
    end
  end

  # Handle query/mutation errors from PubSub
  def handle_info(%Broadcast{event: "query:error", payload: payload}, socket) do
    %{id: id, error: error, topic: topic} = payload
    
    # Unsubscribe from the query topic to prevent memory leaks
    Phoenix.PubSub.unsubscribe(socket.pubsub, topic)
    
    {:push, {:text, Message.Error.new(id, error)}, socket}
  end
  
  # Handle query/mutation timeouts
  def handle_info(%Broadcast{event: "query:timeout", payload: payload}, socket) do
    %{id: id, topic: topic} = payload
    
    # Unsubscribe from the query topic to prevent memory leaks
    Phoenix.PubSub.unsubscribe(socket.pubsub, topic)
    
    {:push, {:text, Message.Error.new(id, "Query execution timed out")}, socket}
  end

  def handle_info({:complete, id}, socket) do
    {:push, {:text, Message.Complete.new(id)}, socket}
  end

  def handle_info(message, socket) do
    if function_exported?(socket.handler, :handle_message, 2) do
      socket.handler.handle_message(message, socket)
    else
      {:ok, socket}
    end
  end

  @doc """
  Process was stopped.
  """
  @spec terminate(term(), socket()) :: :ok
  def terminate(reason, _socket) do
    debug("terminated: #{inspect(reason)}")
    :ok
  end

  @doc """
  Callbacks for parsed JSON payloads coming in from a client.

  See:
  https://github.com/enisdenjo/graphql-ws/blob/master/PROTOCOL.md
  """
  @spec handle_inbound(map(), socket()) :: reply_inbound()
  def handle_inbound(%{"type" => "connection_init"}, %{initialized?: true} = socket) do
    close(4429, "Too many initialisation requests", socket)
  end

  def handle_inbound(%{"type" => "connection_init"} = message, %{handler: handler} = socket) do
    if function_exported?(handler, :handle_init, 2) do
      case handler.handle_init(Map.get(message, "payload", %{}), socket) do
        {:ok, payload, socket} ->
          {:reply, :ok, {:text, Message.ConnectionAck.new(payload)}, %{socket | initialized?: true}}

        {:error, payload, socket} ->
          {:reply, :ok, {:text, Message.Error.new(payload)}, socket}
      end
    else
      {:reply, :ok, {:text, Message.ConnectionAck.new()}, %{socket | initialized?: true}}
    end
  end

  def handle_inbound(%{"type" => "subscribe"}, %{initialized?: false} = socket) do
    close(4400, "Subscribe message received before ConnectionInit", socket)
  end

  def handle_inbound(%{"id" => id, "type" => "subscribe", "payload" => payload}, socket) do
    payload
    |> handle_subscribe(id, socket)
  end

  def handle_inbound(%{"id" => id, "type" => "complete"}, socket) do
    socket.subscriptions
    |> Enum.find_value(fn
      {topic, ^id} ->
        {:ok, topic}

      _ ->
        false
    end)
    |> case do
      {:ok, topic} ->
        debug("unsubscribing from topic #{topic}")
        Phoenix.PubSub.unsubscribe(socket.pubsub, topic)
        Absinthe.Subscription.unsubscribe(socket.endpoint, topic)

        {:ok, %{socket | subscriptions: Map.delete(socket.subscriptions, id)}}

      _ ->
        {:ok, socket}
    end
  end

  def handle_inbound(%{"type" => "ping"}, socket),
    do: {:reply, :ok, {:text, Message.Pong.new()}, socket}

  def handle_inbound(msg, socket) do
    warn("unhandled message #{inspect(msg)}")
    close(4400, "Unhandled message from client", socket)
  end

  @doc """
  Subscribe messages in graphql-ws may include a subscription, implying a subscription to
  a long term stream of data. These messages may also be queries or mutations, so do not require
  a stream.
  """
  def handle_subscribe(payload, id, socket) do
    with %{schema: schema} <- socket.absinthe,
         {:ok, variables} <- parse_variables(payload),
         {:ok, query} <- parse_query(payload) do
      opts = socket.absinthe.opts |> Keyword.merge(variables: variables)

      Absinthe.Logger.log_run(:debug, {
        query,
        schema,
        [],
        opts
      })

      run_doc(socket, id, query, socket.absinthe, opts)
    else
      _ ->
        {:ok, socket}
    end
  end

  defp close(code, message, socket) do
    {:reply, :ok, {:close, code, message}, socket}
  end

  defp parse_query(%{"query" => query}) when is_binary(query), do: {:ok, query}
  defp parse_query(_), do: {:ok, ""}

  defp parse_variables(%{"variables" => variables}) when is_map(variables), do: {:ok, variables}
  defp parse_variables(_), do: {:ok, %{}}

  def pipeline(schema, options) do
    schema
    |> Absinthe.Pipeline.for_document(options)
  end

  defp run_doc(socket, id, query, config, opts) do
    case determine_operation_type(query) do
      :subscription ->
        handle_subscription(socket, id, query, config, opts)
      _ ->
        handle_query_or_mutation(socket, id, query, config, opts)
    end
  end

  # Handle subscription operations
  defp handle_subscription(socket, id, query, config, opts) do
    case run(query, config[:schema], config[:pipeline], opts) do
      {:ok, %{"subscribed" => topic}, context} ->
        debug("subscribed to topic #{topic}")

        :ok =
          Phoenix.PubSub.subscribe(
            socket.pubsub,
            topic,
            # metadata: {:fastlane, self(), @serializer, []},
            link: true
          )

        socket = merge_opts(socket, context: context)
        {:ok, %{socket | subscriptions: Map.put(socket.subscriptions, topic, id)}}

      {:ok, %{data: _} = reply, context} ->
        queue_complete_message(id)
        socket = merge_opts(socket, context: context)
        {:reply, :ok, {:text, Message.Next.new(id, reply)}, socket}

      {:ok, %{errors: errors}, context} ->
        socket = merge_opts(socket, context: context)
        {:reply, :ok, {:text, Message.Error.new(id, errors)}, socket}

      {:error, reply} ->
        {:reply, :error, {:text, Message.Error.new(id, reply)}, socket}
    end
  end

  # Handle query or mutation operations using Task.Supervisor for non-blocking execution
  defp handle_query_or_mutation(socket, id, query, config, opts) do
    # Create a unique topic for this query
    query_topic = "graphql_ws:query:#{id}"
    
    # Subscribe to the query topic
    :ok = Phoenix.PubSub.subscribe(socket.pubsub, query_topic)
    
    # Get the query execution timeout from config (default: 30 seconds)
    timeout = Application.get_env(:absinthe_graphql_ws, :query_timeout, 30_000)
    
    # Use the Task.Supervisor to run the query with proper supervision
    task_supervisor_name = get_task_supervisor()
    
    # Execute task on a potentially remote node to distribute work across the cluster
    node = choose_execution_node()
    
    # Start a supervised task to execute the query on the selected node
    task_supervisor = Module.concat(task_supervisor_name, TaskSupervisor)
    Task.Supervisor.async_nolink(
      {task_supervisor, node},
      fn ->
        try do
          # Execute the query with a timeout
          case run(query, config[:schema], config[:pipeline], opts) do
            {:ok, result, context} ->
              # Publish the result back to the socket process
              Phoenix.PubSub.broadcast(
                socket.pubsub,
                query_topic,
                %Broadcast{
                  event: "query:data",
                  payload: %{id: id, result: result, context: context, topic: query_topic}
                }
              )
            
            {:error, error} ->
              # Publish the error back to the socket process
              Phoenix.PubSub.broadcast(
                socket.pubsub,
                query_topic,
                %Broadcast{
                  event: "query:error",
                  payload: %{id: id, error: error, topic: query_topic}
                }
              )
          end
        rescue
          e ->
            # Handle exceptions during query execution
            Phoenix.PubSub.broadcast(
              socket.pubsub,
              query_topic,
              %Broadcast{
                event: "query:error",
                payload: %{id: id, error: Exception.message(e), topic: query_topic}
              }
            )
        catch
          :exit, reason ->
            # Handle task exit
            Phoenix.PubSub.broadcast(
              socket.pubsub,
              query_topic,
              %Broadcast{
                event: "query:error",
                payload: %{id: id, error: "Operation failed: #{inspect(reason)}", topic: query_topic}
              }
            )
        end
      end,
      timeout: timeout
    )
    |> monitor_task(id, query_topic, socket.pubsub, timeout)

    # Return immediately, allowing other operations to be processed
    {:ok, socket}
  end
  
  # Monitor the task and handle timeouts
  defp monitor_task(task, id, topic, pubsub, timeout) do
    # Spawn a monitoring process that will handle the timeout
    spawn(fn ->
      # Set up a timer for the timeout
      timer_ref = Process.send_after(self(), :timeout, timeout)
      
      # Wait for the task to complete or timeout
      receive do
        {ref, _result} when ref == task.ref ->
          # Task completed successfully, cancel the timer
          Process.cancel_timer(timer_ref)
        
        :timeout ->
          # Task timed out, notify the socket process
          Phoenix.PubSub.broadcast(
            pubsub,
            topic,
            %Broadcast{
              event: "query:timeout",
              payload: %{id: id, topic: topic}
            }
          )
          
          # Cancel the task if it's still running
          Task.shutdown(task, :brutal_kill)
      end
    end)
  end
  
  # Get the task supervisor, creating it if necessary
  defp get_task_supervisor do
    supervisor_name = Absinthe.GraphqlWS.QuerySupervisor
    
    # Ensure the supervisor is started
    case Process.whereis(supervisor_name) do
      nil ->
        # Supervisor doesn't exist, start it
        {:ok, _pid} = Absinthe.GraphqlWS.QuerySupervisor.start_link()
        supervisor_name
      _pid ->
        supervisor_name
    end
  end
  
  # Choose a node to execute the query on for load balancing
  defp choose_execution_node do
    # Get all connected nodes, including the local node
    nodes = [node() | Node.list()]
    
    # Select a random node from the cluster for basic load distribution
    # In a production system, you might want more sophisticated node selection
    # based on current load, locality, etc.
    Enum.random(nodes)
  end

  # New function to determine operation type from the query
  defp determine_operation_type(query) do
    # Simple pattern matching for operation type
    if String.match?(query, ~r/subscription\s*{/i) or String.match?(query, ~r/subscription\s+\w+/i) do
      :subscription
    else
      :query_or_mutation
    end
  end

  defp run(document, schema, pipeline, options) do
    {module, fun} = pipeline

    case Absinthe.Pipeline.run(document, apply(module, fun, [schema, options])) do
      {:ok, %{result: result, execution: res}, _phases} ->
        {:ok, result, res.context}

      {:error, msg, _phases} ->
        {:error, msg}
    end
  end

  defp merge_opts(socket, opts) do
    %{socket | absinthe: %{socket.absinthe | opts: opts}}
  end

  defp queue_complete_message(id), do: send(self(), {:complete, id})
end

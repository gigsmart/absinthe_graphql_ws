# AbsintheGraphQL.WS Incremental Delivery

WebSocket transport support for GraphQL `@defer` and `@stream` directives.

## Overview

This package extends `absinthe_graphql_ws` to support incremental delivery over WebSocket connections using the GraphQL-WS protocol. It enables real-time streaming of deferred fragments and list items while maintaining protocol compliance.

## Features

- ✅ **GraphQL-WS Protocol**: Full compliance with GraphQL-WS specification
- ✅ **Bidirectional Streaming**: Supports both client subscriptions and server-initiated streaming
- ✅ **Message Sequencing**: Proper ordering of initial, incremental, and completion messages
- ✅ **Error Handling**: Graceful error recovery and connection management
- ✅ **Resource Management**: Automatic cleanup of streaming operations

## Installation

This functionality is included in the main `absinthe_graphql_ws` package when using incremental delivery:

```elixir
def deps do
  [
    {:absinthe, "~> 1.8"},
    {:absinthe_graphql_ws, "~> 0.3"}
  ]
end
```

## Configuration

### Basic Setup

```elixir
# endpoint.ex
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app
  
  socket "/graphql/websocket", Absinthe.GraphQL.WS.Socket,
    websocket: [
      subprotocols: ["graphql-ws"],
      timeout: 45_000
    ],
    incremental: [
      enabled: true,
      default_batch_size: 5,
      max_pending_operations: 100
    ]
end
```

### Advanced Configuration

```elixir
# config/config.exs
config :absinthe_graphql_ws, :incremental,
  # Enable incremental delivery
  enabled: true,
  
  # Default stream batch size
  default_stream_batch_size: 10,
  
  # Maximum pending operations per connection
  max_pending_operations: 50,
  
  # Operation timeout
  operation_timeout: 30_000,
  
  # Cleanup interval for abandoned operations
  cleanup_interval: 60_000,
  
  # Enable telemetry
  enable_telemetry: true
```

## Usage

### Client-Side Setup (JavaScript)

```javascript
import { Client, createClient } from 'graphql-ws';

const client = createClient({
  url: 'ws://localhost:4000/graphql/websocket',
  connectionParams: {
    // Authentication if needed
    token: getAuthToken()
  }
});

// Query with incremental delivery
const query = `
  query GetUserProfile($userId: ID!) {
    user(id: $userId) {
      id
      name
      
      # Deferred profile data
      ... @defer(label: "profile") {
        email
        profile {
          bio
          avatar
        }
      }
      
      # Streamed posts
      posts @stream(initialCount: 2, label: "posts") {
        id
        title
        content
      }
    }
  }
`;

const unsubscribe = client.subscribe(
  {
    query,
    variables: { userId: "123" }
  },
  {
    next: (data) => {
      if (data.data) {
        // Initial or incremental data
        console.log('Data received:', data);
        updateUI(data);
      }
    },
    error: (error) => {
      console.error('GraphQL error:', error);
    },
    complete: () => {
      console.log('Query completed');
    }
  }
);
```

### Message Flow

The WebSocket transport handles the following message sequence:

#### 1. Initial Response
```json
{
  "id": "query-1",
  "type": "next",
  "payload": {
    "data": {
      "user": {
        "id": "123",
        "name": "Alice"
      }
    },
    "pending": [
      {"label": "profile", "path": ["user"]},
      {"label": "posts", "path": ["user", "posts"]}
    ]
  }
}
```

#### 2. Incremental Responses
```json
{
  "id": "query-1", 
  "type": "next",
  "payload": {
    "incremental": [{
      "label": "profile",
      "path": ["user"],
      "data": {
        "email": "alice@example.com",
        "profile": {
          "bio": "Software engineer",
          "avatar": "avatar.jpg"
        }
      }
    }]
  }
}
```

```json
{
  "id": "query-1",
  "type": "next", 
  "payload": {
    "incremental": [{
      "label": "posts",
      "path": ["user", "posts"],
      "items": [
        {"id": "3", "title": "Post 3", "content": "..."},
        {"id": "4", "title": "Post 4", "content": "..."}
      ]
    }]
  }
}
```

#### 3. Completion
```json
{
  "id": "query-1",
  "type": "complete"
}
```

## Server-Side Implementation

### Phoenix Channel Integration

```elixir
defmodule MyAppWeb.GraphQLChannel do
  use Phoenix.Channel
  use Absinthe.Phoenix.Channel,
    schema: MyApp.Schema,
    incremental: [
      enabled: true,
      transport: Absinthe.GraphQL.WS.Incremental.Transport
    ]

  def join("graphql", _params, socket) do
    # Authentication and setup
    {:ok, socket}
  end

  def handle_in("doc", payload, socket) do
    # Handle GraphQL queries with incremental delivery
    Absinthe.Phoenix.Channel.handle_in("doc", payload, socket)
  end
end
```

### Custom Transport Handler

```elixir
defmodule MyApp.CustomIncrementalTransport do
  @behaviour Absinthe.Incremental.Transport
  
  @impl true
  def send_initial(state, response) do
    # Custom handling of initial response
    send_message(state.socket, %{
      type: "next",
      payload: response
    })
    
    {:ok, state}
  end
  
  @impl true  
  def send_incremental(state, response) do
    # Custom handling of incremental responses
    send_message(state.socket, %{
      type: "next", 
      payload: %{incremental: response}
    })
    
    {:ok, state}
  end
  
  @impl true
  def complete(state) do
    send_message(state.socket, %{type: "complete"})
    :ok
  end
end
```

## Advanced Features

### Connection Pooling

```elixir
# Manage multiple streaming operations per connection
defmodule MyApp.IncrementalConnectionManager do
  use GenServer
  
  def start_link(socket_id) do
    GenServer.start_link(__MODULE__, socket_id, name: via_tuple(socket_id))
  end
  
  def add_operation(socket_id, operation_id, operation) do
    GenServer.call(via_tuple(socket_id), {:add_operation, operation_id, operation})
  end
  
  def complete_operation(socket_id, operation_id) do
    GenServer.call(via_tuple(socket_id), {:complete_operation, operation_id})
  end
  
  # Implementation...
end
```

### Message Ordering

The transport automatically handles:
- Message sequencing per operation
- Concurrent operation isolation  
- Proper cleanup on connection close

### Error Recovery

```elixir
# Automatic retry and fallback mechanisms
config :absinthe_graphql_ws, :incremental,
  error_recovery: [
    max_retries: 3,
    backoff_strategy: :exponential,
    fallback_to_sync: true
  ]
```

## Performance Optimization

### Batch Size Tuning

```elixir
# Configure per-field batch sizes
query do
  field :posts, list_of(:post) do
    meta stream_batch_size: 5  # Small items
    resolve &Resolvers.list_posts/2
  end
  
  field :large_items, list_of(:large_item) do  
    meta stream_batch_size: 2  # Large items
    resolve &Resolvers.list_large_items/2
  end
end
```

### Connection Limits

```elixir
# Prevent resource exhaustion
config :absinthe_graphql_ws,
  max_connections: 1000,
  max_operations_per_connection: 10,
  connection_timeout: 300_000  # 5 minutes
```

### Memory Management

The transport includes automatic:
- Operation cleanup on completion
- Memory leak prevention
- Resource monitoring

## Monitoring

### Telemetry Events

```elixir
:telemetry.attach_many(
  "graphql-ws-incremental",
  [
    [:absinthe_graphql_ws, :incremental, :operation, :start],
    [:absinthe_graphql_ws, :incremental, :operation, :stop],
    [:absinthe_graphql_ws, :incremental, :message, :sent],
    [:absinthe_graphql_ws, :incremental, :error]
  ],
  &MyApp.Telemetry.handle_event/4,
  %{}
)
```

### Metrics to Track

- Active WebSocket connections
- Operations per connection
- Message throughput
- Error rates
- Memory usage per connection

## Troubleshooting

### Common Issues

1. **Messages not received in order**
   - Check message ID sequencing
   - Verify client library handles async messages
   - Review network conditions

2. **High memory usage**
   - Reduce batch sizes
   - Implement connection limits
   - Monitor operation cleanup

3. **Connection drops**
   - Check timeout settings
   - Implement reconnection logic
   - Monitor resource usage

### Debug Mode

```elixir
# Enable detailed logging
config :absinthe_graphql_ws, :incremental,
  debug: true,
  log_messages: true,
  log_operations: true
```

### Health Checks

```elixir
# Add to your health check endpoint
defmodule MyAppWeb.HealthController do
  def websocket_health(conn, _params) do
    stats = Absinthe.GraphQL.WS.Incremental.get_stats()
    
    json(conn, %{
      active_connections: stats.connections,
      active_operations: stats.operations,
      memory_usage: stats.memory_mb
    })
  end
end
```

## Protocol Specification

This implementation follows the [GraphQL over WebSocket Protocol](https://github.com/enisdenjo/graphql-ws/blob/master/PROTOCOL.md) with extensions for incremental delivery:

- Uses standard GraphQL-WS message types
- Maintains connection lifecycle compatibility  
- Extends with incremental-specific payload formats
- Preserves subscription functionality

## Examples

See the [examples/](examples/) directory for:
- Complete Phoenix application setup
- Client-side integration examples
- Performance testing scripts
- Custom transport implementations

## Contributing

Issues and contributions welcome! Focus areas:
- Protocol compliance testing
- Performance optimization
- Client library compatibility
- Documentation improvements
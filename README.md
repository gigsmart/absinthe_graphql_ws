# AbsintheGraphqlWS

Adds a websocket transport for the [GraphQL over WebSocket
Protocol](https://github.com/enisdenjo/graphql-ws/blob/master/PROTOCOL.md) to Absinthe running in
Phoenix.

See the [hex docs](https://hexdocs.pm/absinthe_graphql_ws) for more information.

## References

- https://github.com/enisdenjo/graphql-ws
- This project is heavily inspired by [subscriptions-transport-ws](https://github.com/maartenvanvliet/subscriptions-transport-ws)

## Installation

Add `absinthe_graphql_ws` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:absinthe_graphql_ws, "~> 0.3"}
  ]
end
```

## Usage

### Using the websocket client

```elixir
defmodule ExampleWeb.ApiClient do
  use GenServer

  alias Absinthe.GraphqlWS.Client

  def start(endpoint) do
    Client.start(endpoint)
  end

  def init(args) do
    {:ok, args}
  end

  def stop(client) do
    Client.close(client)
  end

  @gql """
  mutation ChangeSomething($id: String!) {
    changeSomething(id: $id) {
      id
      name
    }
  }
  """
  def change_something(client, thing_id) do
    {:ok, body} = Client.query(client, @gql, id: thing_id)

    case get_in(body, ~w[data changeSomething]) do
      nil -> {:error, get_in(body, ~w[errors])}
      thing -> {:ok, thing}
    end
  end

  @gql """
  query GetSomething($id: UUID!) {
    thing(id: $id) {
      id
      name
    }
  }
  """
  def get_thing(client, thing_id) do
    case Client.query(client, @gql, id: thing_id) do
      {:ok, %{"data" => %{"thing" => nil}}} ->
        nil

      {:ok, %{"data" => %{"thing" => result}}} ->
        {:ok, result}

      {:ok, errors} when is_list(errors) ->
        nil
    end
  end

  @gql """
  subscription ThingChanges($thingId: String!){
    thingChanges(thingId: $projectId) {
      id
      name
    }
  }
  """
  # handler is a pid for a process that implements `handle_info/4` as below
  def thing_changes(client, thing_id: thing_id, handler: handler) do
    Client.subscribe(client, @gql, %{thingId: thing_id}, handler)
  end
end
```

An example of handle_info

```elixir
  @impl true
  def handle_info({:subscription, _id, %{"data" => %{"thingChanges" => thing_changes}}}, %{assigns: %{thing: thing}} = socket) do
    changes = thing_changes |> Enum.find(&(&1["id"] == thing.id))
    socket |> do_cool_update(changes["things"]) |> noreply()
  end
```

## Incremental Delivery

AbsintheGraphqlWS supports GraphQL `@defer` and `@stream` directives for incremental delivery over WebSocket connections using the GraphQL-WS protocol. This enables real-time streaming of deferred fragments and list items while maintaining protocol compliance.

Key features:
- ✅ **GraphQL-WS Protocol**: Full compliance with GraphQL-WS specification
- ✅ **Bidirectional Streaming**: Supports both client subscriptions and server-initiated streaming  
- ✅ **Message Sequencing**: Proper ordering of initial, incremental, and completion messages
- ✅ **Error Handling**: Graceful error recovery and connection management

**Installation with incremental delivery:**

```elixir
def deps do
  [
    {:absinthe, git: "https://github.com/gigsmart/absinthe.git", branch: "gigmart/defer-stream-incremental"},
    {:absinthe_graphql_ws, git: "https://github.com/gigsmart/absinthe_graphql_ws.git", branch: "gigmart/defer-stream-incremental"}
  ]
end
```

**Example usage:**

```javascript
// Client-side WebSocket connection
import { createClient } from 'graphql-ws';

const client = createClient({
  url: 'ws://localhost:4000/graphql/websocket'
});

const unsubscribe = client.subscribe(
  {
    query: `
      query GetUserProfile($userId: ID!) {
        user(id: $userId) {
          id
          name
          ... @defer(label: "profile") {
            email
            profile { bio }
          }
          posts @stream(initialCount: 2, label: "posts") {
            id
            title
          }
        }
      }
    `,
    variables: { userId: "123" }
  },
  {
    next: (data) => console.log('Received data:', data),
    error: (error) => console.error('GraphQL error:', error),
    complete: () => console.log('Query completed')
  }
);
```

For comprehensive documentation on WebSocket incremental delivery patterns, see [Absinthe Incremental Delivery Guide](https://hexdocs.pm/absinthe/incremental-delivery.html).

## Benchmarks

Benchmarks live in the `benchmarks` directory, and can be run with `MIX_ENV=bench mix run
benchmarks/<file>`.

## Contributing

- Pull requests that may be rebased are preferrable to merges or squashes.
- Please **do not** increment the version number in pull requests.

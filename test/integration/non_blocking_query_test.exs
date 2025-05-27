defmodule Absinthe.GraphqlWS.NonBlockingQueryTest do
  use ExUnit.Case

  defp setup_client(_context) do
    assert {:ok, client} = Test.Client.start()
    on_exit(fn -> Test.Client.close(client) end)
    [client: client]
  end

  def send_connection_init(%{client: client}) do
    :ok = Test.Client.push(client, %{type: "connection_init"})

    assert {:ok, [{:text, json}]} = Test.Client.get_new_replies(client)
    assert %{"type" => "connection_ack", "payload" => %{}} == Jason.decode!(json)

    :ok
  end

  defp assert_json_received(client, payload) do
    assert {:ok, [{:text, json}]} = Test.Client.get_new_replies(client)
    # Compare decoded JSON to handle different field ordering
    assert Jason.decode!(json) == payload
  end

  defp assert_json_received_unordered(client, expected_payloads) do
    {:ok, replies} = Test.Client.get_new_replies(client)
    # Filter out non-text messages (like :close)
    received_jsons =
      Enum.flat_map(replies, fn
        {:text, json} -> [Jason.decode!(json)]
        _ -> []
      end)

    # Verify all expected payloads are in the received jsons
    for expected <- expected_payloads do
      assert Enum.any?(received_jsons, fn received ->
               # Match on id and type, then check data separately (to handle different response orders)
               received["id"] == expected["id"] &&
                 received["type"] == expected["type"] &&
                 (received["type"] != "next" || compare_payloads(received["payload"], expected["payload"]))
             end),
             "Expected to receive payload: #{inspect(expected)}"
    end
  end

  defp compare_payloads(%{"data" => data1}, %{"data" => data2}) do
    # In a real implementation, you might need more sophisticated comparison
    # but for our test, a simple equality check should work
    data1 == data2
  end

  defp compare_payloads(payload1, payload2), do: payload1 == payload2

  describe "concurrent queries" do
    setup [:setup_client, :send_connection_init]

    test "multiple queries are processed concurrently without blocking", %{client: client} do
      # Create a slow query (simulated delay in the schema)
      slow_id = "slow-query"

      :ok =
        Test.Client.push(client, %{
          id: slow_id,
          type: "subscribe",
          payload: %{
            query: """
            query {
              slow_thing {
                name
              }
            }
            """
          }
        })

      # Immediately send a fast query
      fast_id = "fast-query"

      :ok =
        Test.Client.push(client, %{
          id: fast_id,
          type: "subscribe",
          payload: %{
            query: """
            query {
              things {
                name
              }
            }
            """
          }
        })

      # The fast query should complete before the slow query
      # First, we should get the fast query response
      assert_json_received(client, %{
        "payload" => %{
          "data" => %{
            "things" => [
              %{"name" => "one"},
              %{"name" => "two"}
            ]
          }
        },
        "type" => "next",
        "id" => fast_id
      })

      assert_json_received(client, %{
        "payload" => %{},
        "type" => "complete",
        "id" => fast_id
      })

      # Then, we should get the slow query response
      assert_json_received(client, %{
        "payload" => %{
          "data" => %{
            "slow_thing" => %{"name" => "slow"}
          }
        },
        "type" => "next",
        "id" => slow_id
      })

      assert_json_received(client, %{
        "payload" => %{},
        "type" => "complete",
        "id" => slow_id
      })
    end

    test "multiple concurrent queries all complete correctly", %{client: client} do
      # Send multiple queries at once
      query_count = 5

      Enum.each(1..query_count, fn i ->
        id = "concurrent-query-#{i}"

        :ok =
          Test.Client.push(client, %{
            id: id,
            type: "subscribe",
            payload: %{
              query: """
              query {
                things {
                  name
                }
              }
              """
            }
          })
      end)

      # Collect all expected "next" and "complete" messages
      expected_nexts =
        Enum.map(1..query_count, fn i ->
          %{
            "payload" => %{
              "data" => %{
                "things" => [
                  %{"name" => "one"},
                  %{"name" => "two"}
                ]
              }
            },
            "type" => "next",
            "id" => "concurrent-query-#{i}"
          }
        end)

      expected_completes =
        Enum.map(1..query_count, fn i ->
          %{
            "payload" => %{},
            "type" => "complete",
            "id" => "concurrent-query-#{i}"
          }
        end)

      # Allow time for all queries to complete
      Process.sleep(500)

      # Verify all expected messages were received (order may vary)
      all_expected = expected_nexts ++ expected_completes
      assert_json_received_unordered(client, all_expected)
    end
  end
end

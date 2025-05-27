defmodule Absinthe.GraphqlWS.QuerySupervisor do
  @moduledoc """
  Supervisor for managing GraphQL query execution tasks.
  
  This supervisor handles the execution of GraphQL queries in a distributed,
  fault-tolerant manner, allowing queries to be executed across the cluster.
  """
  
  # Task.Supervisor is just a name - it doesn't provide a __using__ macro
  # Instead, we'll use DynamicSupervisor with the :simple_one_for_one strategy
  use Supervisor
  
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @impl true
  def init(_opts) do
    children = [
      {Task.Supervisor, name: __MODULE__.TaskSupervisor}
    ]
    
    Supervisor.init(children, strategy: :one_for_one)
  end
end

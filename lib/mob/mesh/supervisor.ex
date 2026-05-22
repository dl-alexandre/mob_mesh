defmodule Mob.Mesh.Supervisor do
  @moduledoc """
  Supervisor for a single `Mob.Mesh.MeshBridge`.
  """

  use Supervisor

  alias Mob.Mesh.MeshBridge

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :supervisor_name))
  end

  @impl true
  def init(opts) do
    Supervisor.init([{MeshBridge, opts}], strategy: :one_for_one)
  end
end

defmodule Mob.Mesh.Store.Behaviour do
  @moduledoc """
  Behaviour for mesh store-and-forward backends.

  Store modules own their process state and expose a small queue API to
  `Mob.Mesh.MeshBridge`. Persistent implementations can use this behaviour to
  provide DETS, SQLite, LMDB, or application-specific durable storage while the
  bridge continues to use the same routing contract.
  """

  alias Mob.Mesh.Router.Envelope

  @type destination :: term()

  @callback start_link(keyword()) :: GenServer.on_start()
  @callback put(GenServer.server(), destination(), Envelope.t()) :: :ok | {:error, term()}
  @callback pop(GenServer.server(), destination()) :: [Envelope.t()]
  @callback list(GenServer.server()) :: %{optional(destination()) => [Envelope.t()]}
end

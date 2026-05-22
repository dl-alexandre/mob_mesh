defmodule Mob.Mesh do
  @moduledoc """
  Public entry point for the mob mesh transport layer.

  `Mob.Mesh` exposes a `Mob.Transport` compatible bridge module and convenience
  functions for starting and using that bridge directly. Applications that
  already use `Mob.Transport.Adapter` can set `Mob.Mesh.bridge_module()` as the
  wrapped transport.
  """

  alias Mob.Mesh.{MeshBridge, Supervisor}

  @type peer_id :: Mob.Transport.peer_id()

  @doc """
  Returns the transport module implemented by this package.
  """
  @spec bridge_module() :: module()
  def bridge_module, do: MeshBridge

  @doc """
  Starts a mesh bridge process.

  Pass a stable `:node_id` in production, such as a persisted device UUID or
  public-key fingerprint. The generated default is useful for tests and
  short-lived local processes only.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: MeshBridge.start_link(opts)

  @doc """
  Returns a child specification for a mesh bridge.
  """
  @spec child_spec(keyword()) :: Elixir.Supervisor.child_spec()
  def child_spec(opts), do: MeshBridge.child_spec(opts)

  @doc """
  Starts a supervisor containing one mesh bridge.
  """
  @spec start_supervised(keyword()) :: Elixir.Supervisor.on_start()
  def start_supervised(opts), do: Supervisor.start_link(opts)

  @doc """
  Sends an application payload through the mesh.
  """
  @spec send_message(GenServer.server(), peer_id(), binary(), keyword()) :: :ok | {:error, term()}
  def send_message(mesh, destination, payload, opts \\ []) when is_binary(payload) do
    MeshBridge.send_frame(mesh, destination, payload, opts)
  end

  @doc """
  Stops a mesh bridge process.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(mesh), do: MeshBridge.stop(mesh)
end

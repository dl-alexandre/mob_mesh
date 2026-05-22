defmodule Mob.Mesh do
  @moduledoc """
  Public entry point for the mob mesh transport layer.

  `Mob.Mesh` exposes a `Mob.Transport` compatible bridge module and convenience
  functions for starting and using that bridge directly. Applications that
  already use `Mob.Transport.Adapter` can set `Mob.Mesh.bridge_module()` as the
  wrapped transport.
  """

  alias Mob.Mesh.MeshBridge

  @type peer_id :: Mob.Transport.peer_id()

  @doc """
  Returns the transport module implemented by this package.
  """
  @spec bridge_module() :: module()
  def bridge_module, do: MeshBridge

  @doc """
  Starts a mesh bridge process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: MeshBridge.start_link(opts)

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

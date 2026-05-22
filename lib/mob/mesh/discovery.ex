defmodule Mob.Mesh.Discovery do
  @moduledoc """
  Tracks the local mesh topology learned from underlying transports.
  """

  use GenServer

  @type peer_id :: term()
  @type transport_name :: atom()
  @type peer :: %{
          id: peer_id(),
          transport: transport_name(),
          metadata: term(),
          seen_at: integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec peer_up(GenServer.server(), transport_name(), peer_id(), term()) :: :ok
  def peer_up(discovery, transport, peer_id, metadata \\ %{}) do
    GenServer.call(discovery, {:peer_up, transport, peer_id, metadata})
  end

  @spec peer_down(GenServer.server(), peer_id()) :: :ok
  def peer_down(discovery, peer_id) do
    GenServer.call(discovery, {:peer_down, peer_id})
  end

  @spec peers(GenServer.server()) :: %{optional(peer_id()) => peer()}
  def peers(discovery) do
    GenServer.call(discovery, :peers)
  end

  @impl true
  def init(_opts), do: {:ok, %{peers: %{}}}

  @impl true
  def handle_call({:peer_up, transport, peer_id, metadata}, _from, state) do
    peer = %{
      id: peer_id,
      transport: transport,
      metadata: metadata,
      seen_at: System.monotonic_time(:millisecond)
    }

    {:reply, :ok, %{state | peers: Map.put(state.peers, peer_id, peer)}}
  end

  def handle_call({:peer_down, peer_id}, _from, state) do
    {:reply, :ok, %{state | peers: Map.delete(state.peers, peer_id)}}
  end

  def handle_call(:peers, _from, state), do: {:reply, state.peers, state}
end

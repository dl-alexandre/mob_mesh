ExUnit.start()

defmodule Mob.Mesh.FakeTransport do
  @moduledoc false

  @behaviour Mob.Transport

  use GenServer

  @impl true
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def send_frame(transport, peer_id, frame, opts) do
    GenServer.call(transport, {:send_frame, peer_id, frame, opts})
  end

  @impl true
  def broadcast_frame(transport, frame, opts) do
    GenServer.call(transport, {:broadcast_frame, frame, opts})
  end

  @impl true
  def stop(transport), do: GenServer.stop(transport)

  @impl true
  def init(opts) do
    {:ok,
     %{
       event_target: Keyword.fetch!(opts, :event_target),
       owner: Keyword.get(opts, :owner, self())
     }}
  end

  @impl true
  def handle_call({:send_frame, peer_id, frame, opts}, _from, state) do
    send(state.owner, {:fake_transport_send, peer_id, frame, opts})
    {:reply, :ok, state}
  end

  def handle_call({:broadcast_frame, frame, opts}, _from, state) do
    send(state.owner, {:fake_transport_broadcast, frame, opts})
    {:reply, :ok, state}
  end
end

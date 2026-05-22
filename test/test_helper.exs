ExUnit.start()

Application.ensure_all_started(:telemetry)

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
       owner: Keyword.get(opts, :owner, self()),
       send_reply: Keyword.get(opts, :send_reply, :ok)
     }}
  end

  @impl true
  def handle_call({:send_frame, peer_id, frame, opts}, _from, state) do
    send(state.owner, {:fake_transport_send, peer_id, frame, opts})
    {:reply, state.send_reply, state}
  end

  def handle_call({:broadcast_frame, frame, opts}, _from, state) do
    send(state.owner, {:fake_transport_broadcast, frame, opts})
    {:reply, :ok, state}
  end
end

defmodule Mob.Mesh.FakeStore do
  @moduledoc false

  @behaviour Mob.Mesh.Store.Behaviour

  use GenServer

  @impl true
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def put(store, destination, envelope), do: GenServer.call(store, {:put, destination, envelope})

  @impl true
  def pop(store, destination), do: GenServer.call(store, {:pop, destination})

  @impl true
  def list(store), do: GenServer.call(store, :list)

  @impl true
  def init(opts) do
    {:ok, %{queues: %{}, owner: Keyword.get(opts, :owner)}}
  end

  @impl true
  def handle_call({:put, destination, envelope}, _from, state) do
    if state.owner, do: send(state.owner, {:fake_store_put, destination, envelope})
    queues = Map.update(state.queues, destination, [envelope], &[envelope | &1])
    {:reply, :ok, %{state | queues: queues}}
  end

  def handle_call({:pop, destination}, _from, state) do
    if state.owner, do: send(state.owner, {:fake_store_pop, destination})
    {queue, queues} = Map.pop(state.queues, destination, [])
    {:reply, Enum.reverse(queue), %{state | queues: queues}}
  end

  def handle_call(:list, _from, state) do
    queues =
      Map.new(state.queues, fn {destination, queue} -> {destination, Enum.reverse(queue)} end)

    {:reply, queues, state}
  end
end

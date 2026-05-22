defmodule Mob.Mesh.Store do
  @moduledoc """
  In-memory store-and-forward queue for mesh envelopes.

  This first store is process-local and intentionally replaceable. It provides
  the API that a persistent store can keep in a later phase.
  """

  use GenServer

  @behaviour Mob.Mesh.Store.Behaviour

  alias Mob.Mesh.Router.Envelope

  @type destination :: term()

  @impl Mob.Mesh.Store.Behaviour
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl Mob.Mesh.Store.Behaviour
  @spec put(GenServer.server(), destination(), Envelope.t()) :: :ok | {:error, term()}
  def put(store, destination, %Envelope{} = envelope) do
    GenServer.call(store, {:put, destination, envelope})
  end

  @impl Mob.Mesh.Store.Behaviour
  @spec pop(GenServer.server(), destination()) :: [Envelope.t()]
  def pop(store, destination) do
    GenServer.call(store, {:pop, destination})
  end

  @impl Mob.Mesh.Store.Behaviour
  @spec list(GenServer.server()) :: %{optional(destination()) => [Envelope.t()]}
  def list(store) do
    GenServer.call(store, :list)
  end

  @impl true
  def init(opts) do
    {:ok, %{queues: %{}, limit: Keyword.get(opts, :limit, 1_000)}}
  end

  @impl true
  def handle_call({:put, destination, envelope}, _from, state) do
    queues =
      Map.update(state.queues, destination, [envelope], fn queue ->
        [envelope | queue] |> Enum.take(state.limit)
      end)

    {:reply, :ok, %{state | queues: queues}}
  end

  def handle_call({:pop, destination}, _from, state) do
    {queue, queues} = Map.pop(state.queues, destination, [])
    {:reply, Enum.reverse(queue), %{state | queues: queues}}
  end

  def handle_call(:list, _from, state) do
    queues =
      Map.new(state.queues, fn {destination, queue} -> {destination, Enum.reverse(queue)} end)

    {:reply, queues, state}
  end
end

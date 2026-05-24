defmodule Mob.Mesh.MeshBridge do
  @moduledoc """
  `Mob.Transport` implementation for mesh routing.

  MeshBridge owns the Discovery/Router/SeenCache/Store logic for epidemic
  routing and duplicate suppression. It is intended to turn point-to-point
  `Mob.Transport` plugins into a mesh by receiving events from underlying
  transports and delivering payloads to its `:event_target`.

  The `:transports` option starts wrapped `Mob.Transport.Adapter` children and
  uses those adapters for direct and flooded sends. Transports may also be
  managed externally by forwarding their events directly to this bridge as the
  event target.

  NOTE: Mesh remains on legacy event shapes (`{:transport_up, ...}`,
  `{:transport_down, ...}`, `{:frame, ...}`, `{:transport_error, ...}`) until
  full alignment with `Mob.Transport.Event` normalized `{:mob_transport, :mesh, ...}`
  shapes. The Adapter-era internal logic (state tracking, helpers) has been
  pruned; peer transport identity (when not supplied in forwarded metadata)
  uses an explicit sentinel to avoid nils.
  """

  use GenServer
  @behaviour Mob.Transport

  require Logger

  alias Mob.Mesh.{Discovery, Router, SeenCache, Store, Telemetry}
  alias Mob.Mesh.Router.Envelope
  alias Mob.Transport.Adapter

  @magic "mob_mesh:v1"

  @impl true
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @impl true
  def send_frame(mesh, peer_id, frame, opts) when is_binary(frame) do
    GenServer.call(mesh, {:send_frame, peer_id, frame, opts})
  end

  @impl true
  def broadcast_frame(mesh, frame, opts) when is_binary(frame) do
    GenServer.call(mesh, {:broadcast_frame, frame, opts})
  end

  @impl true
  def stop(mesh), do: GenServer.stop(mesh)

  @doc false
  @spec peers(GenServer.server()) :: [Mob.Transport.peer_id()]
  def peers(mesh), do: GenServer.call(mesh, :peers)

  @doc false
  @spec stored(GenServer.server()) :: map()
  def stored(mesh), do: GenServer.call(mesh, :stored)

  @doc "Transport capabilities advertised by this plugin."
  def capabilities, do: [:mesh]

  @doc "Static transport metadata."
  def metadata, do: %{routing: :epidemic}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, event_target} <- fetch_event_target(opts),
         {:ok, transports} <- fetch_transports(opts),
         {:ok, store_module} <- fetch_store(opts),
         {:ok, discovery} <- Discovery.start_link([]),
         {:ok, store} <- start_store(store_module, store_opts(opts)),
         {:ok, adapters} <- start_adapters(transports) do
      {:ok,
       %{
         node_id: Keyword.get_lazy(opts, :node_id, &default_node_id/0),
         event_target: event_target,
         peer_routes: %{},
         adapters: adapters,
         seen: SeenCache.new(Keyword.get(opts, :seen_limit, 4_096)),
         discovery: discovery,
         store: store,
         store_module: store_module
       }}
    end
  end

  @impl true
  def handle_call({:send_frame, destination, frame, opts}, _from, state) do
    envelope = Router.envelope(state.node_id, destination, frame, opts)
    {reply, state} = dispatch_or_store(envelope, state)
    {:reply, reply, remember(envelope.id, state)}
  end

  @impl true
  def handle_call({:broadcast_frame, frame, opts}, _from, state) do
    envelope = Router.envelope(state.node_id, :broadcast, frame, opts)
    {reply, state} = dispatch_or_store(envelope, state)
    {:reply, reply, remember(envelope.id, state)}
  end

  @impl true
  def handle_call(:peers, _from, state) do
    peers =
      state.discovery
      |> Discovery.peers()
      |> Map.values()
      |> Enum.map(fn p -> %{id: p.id, metadata: Map.get(p, :metadata, %{})} end)

    {:reply, peers, state}
  end

  @impl true
  def handle_call(:stored, _from, state), do: {:reply, store_list(state), state}

  @impl true
  def handle_info({:EXIT, pid, _reason}, state) do
    adapters =
      state.adapters
      |> Enum.reject(fn {_transport, adapter} -> adapter == pid end)
      |> Map.new()

    {:noreply, %{state | adapters: adapters}}
  end

  @impl true
  def handle_info({:transport_up, peer_id, metadata}, state) do
    # Transport identity prefers explicit value from forwarded :transport_up
    # metadata (supplied by external sub-transport when it emits to us as
    # event_target). Sentinel avoids nil-transport in peer_routes/discovery.
    transport =
      if is_map(metadata) do
        Map.get(metadata, :transport) || Map.get(metadata, "transport") || :mesh_transitional
      else
        :mesh_transitional
      end

    :ok = Discovery.peer_up(state.discovery, transport, peer_id, metadata)

    state = put_peer_route(state, peer_id, transport, metadata)

    Telemetry.emit(
      [:peer, :discovered],
      %{count: 1},
      peer_metadata(state, peer_id, transport, metadata)
    )

    replay_stored(peer_id, state)
    # Legacy shape (see moduledoc NOTE)
    send(state.event_target, {:transport_up, peer_id, metadata})

    {:noreply, state}
  end

  @impl true
  def handle_info({:transport_down, peer_id}, state) do
    :ok = Discovery.peer_down(state.discovery, peer_id)
    Telemetry.emit([:peer, :down], %{count: 1}, %{node_id: state.node_id, peer_id: peer_id})
    # Legacy shape (see moduledoc NOTE)
    send(state.event_target, {:transport_down, peer_id})
    {:noreply, %{state | peer_routes: Map.delete(state.peer_routes, peer_id)}}
  end

  @impl true
  def handle_info({:frame, peer_id, frame}, state) do
    state = handle_inbound_frame(peer_id, frame, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:transport_error, reason}, state) do
    # Legacy shape (see moduledoc NOTE)
    send(state.event_target, {:transport_error, reason})
    {:noreply, state}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  defp handle_inbound_frame(peer_id, frame, state) do
    case decode(frame) do
      {:ok, %Envelope{} = envelope} ->
        handle_envelope(peer_id, envelope, state)

      :error ->
        # Legacy non-envelope frame passthrough (see moduledoc NOTE)
        send(state.event_target, {:frame, peer_id, frame})
        state
    end
  end

  defp handle_envelope(peer_id, envelope, state) do
    cond do
      SeenCache.member?(state.seen, envelope.id) ->
        state

      local_destination?(envelope, state) ->
        # Mesh-delivered payload (legacy delivery shape retained in transitional)
        send(state.event_target, {:frame, envelope.source, envelope.payload})
        state = remember(envelope.id, state)

        Telemetry.emit(
          [:message, :delivered],
          message_measurements(envelope, state),
          message_metadata(envelope, state)
        )

        if envelope.destination == :broadcast do
          maybe_relay(peer_id, envelope, state)
        else
          state
        end

      true ->
        maybe_relay(peer_id, envelope, remember(envelope.id, state))
    end
  end

  defp maybe_relay(peer_id, envelope, state) do
    if Router.relayable?(envelope) do
      exclude = MapSet.new([peer_id | envelope.path])
      envelope = Router.relay(envelope, state.node_id)
      {_, state} = dispatch_or_store(envelope, state, exclude: exclude)
      state
    else
      state
    end
  end

  defp dispatch_or_store(envelope, state, opts \\ []) do
    case Router.route(envelope, state.peer_routes, opts) do
      {:direct, transport, peer_id} ->
        reply = send_envelope(state, transport, peer_id, envelope)
        if reply == :ok, do: emit_sent(envelope, state, [{transport, peer_id}])
        if reply != :ok, do: report_send_error(state, envelope, [{transport, peer_id, reply}])
        {reply, state}

      {:flood, targets} ->
        {reply, failures} = flood_envelope(state, targets, envelope)
        if failures != [], do: report_send_error(state, envelope, failures)
        emit_relay_result(reply, envelope, state, targets, failures)
        {reply, state}

      :store ->
        :ok = store_put(state, envelope.destination, envelope)

        Telemetry.emit([:message, :stored], message_measurements(envelope, state), %{
          node_id: state.node_id,
          message_id: envelope.id,
          destination: envelope.destination,
          queue_depth: store_depth(state, envelope.destination)
        })

        {:ok, state}
    end
  end

  defp replay_stored(peer_id, state) do
    state.store
    |> state.store_module.pop(peer_id)
    |> Enum.each(fn envelope ->
      _ = dispatch_or_store(envelope, state)
    end)
  end

  defp send_envelope(state, transport, peer_id, envelope) do
    case Map.fetch(state.adapters, transport) do
      {:ok, adapter} -> Adapter.send_frame(adapter, peer_id, encode(envelope), [])
      :error -> {:error, :mesh_transitional_no_internal_adapter}
    end
  end

  defp flood_envelope(state, targets, envelope) do
    results =
      Enum.map(targets, fn {transport, peer_id} ->
        {transport, peer_id, send_envelope(state, transport, peer_id, envelope)}
      end)

    failures = Enum.reject(results, fn {_transport, _peer_id, reply} -> reply == :ok end)

    if length(failures) == length(results) do
      {{:error, {:no_successful_relay, results}}, failures}
    else
      {:ok, failures}
    end
  end

  defp report_send_error(state, envelope, failures) do
    reason = {:mesh_send_failed, envelope.id, failures}
    Logger.debug("mob_mesh send failed: #{inspect(reason)}")

    Telemetry.emit([:message, :error], %{count: 1}, %{
      node_id: state.node_id,
      message_id: envelope.id,
      destination: envelope.destination,
      reason: reason
    })

    # Legacy error shape (see moduledoc NOTE)
    send(state.event_target, {:transport_error, reason})
  end

  defp encode(%Envelope{} = envelope), do: :erlang.term_to_binary({@magic, envelope})

  defp decode(frame) when is_binary(frame) do
    case safe_binary_to_term(frame) do
      {@magic, %Envelope{} = envelope} -> {:ok, envelope}
      _other -> :error
    end
  end

  defp safe_binary_to_term(frame) do
    :erlang.binary_to_term(frame, [:safe])
  rescue
    ArgumentError -> :error
  end

  defp local_destination?(%Envelope{destination: destination}, state) do
    destination in [state.node_id, :broadcast]
  end

  defp fetch_event_target(opts) do
    case Keyword.fetch(opts, :event_target) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      {:ok, other} -> {:error, {:invalid_event_target, other}}
      :error -> {:error, {:missing_required_option, :event_target}}
    end
  end

  defp fetch_transports(opts) do
    case Keyword.get(opts, :transports, []) do
      [] -> {:ok, []}
      transports when is_list(transports) -> {:ok, transports}
      other -> {:error, {:invalid_transports, other}}
    end
  end

  defp store_opts(opts) do
    Keyword.get(opts, :store_opts, [])
  end

  defp fetch_store(opts) do
    store = Keyword.get(opts, :store, Store)

    cond do
      not is_atom(store) ->
        {:error, {:invalid_store, store}}

      Code.ensure_loaded?(store) and function_exported?(store, :start_link, 1) and
        function_exported?(store, :put, 3) and function_exported?(store, :pop, 2) and
          function_exported?(store, :list, 1) ->
        {:ok, store}

      true ->
        {:error, {:invalid_store, store}}
    end
  end

  defp start_store(store, opts) do
    case store.start_link(opts) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      {:error, reason} -> {:error, {:store_start_failed, reason}}
      other -> {:error, {:invalid_store_start_return, other}}
    end
  end

  defp start_adapters(transports) do
    Enum.reduce_while(transports, {:ok, %{}}, fn spec, {:ok, adapters} ->
      with {:ok, name, transport, opts} <- normalize_transport_spec(spec),
           adapter_opts =
             opts
             |> Keyword.put(:transport, transport)
             |> Keyword.put(:event_target, self()),
           {:ok, pid} <- Adapter.start_link(adapter_opts) do
        {:cont, {:ok, Map.put(adapters, name, pid)}}
      else
        {:error, reason} ->
          Enum.each(adapters, fn {_name, pid} -> Adapter.stop(pid) end)
          {:halt, {:error, {:adapter_start_failed, spec, reason}}}
      end
    end)
  end

  defp normalize_transport_spec({name, transport, opts})
       when is_atom(name) and is_atom(transport) and is_list(opts),
       do: {:ok, name, transport, opts}

  defp normalize_transport_spec({name, transport}) when is_atom(name) and is_atom(transport),
    do: {:ok, name, transport, []}

  defp normalize_transport_spec(other), do: {:error, {:invalid_transport_spec, other}}

  defp put_peer_route(state, peer_id, transport, metadata) do
    route = %{
      transport: transport,
      metadata: metadata,
      seen_at: System.monotonic_time(:millisecond)
    }

    %{state | peer_routes: Map.put(state.peer_routes, peer_id, route)}
  end

  defp remember(id, state) do
    seen = SeenCache.put(state.seen, id)
    Telemetry.emit([:seen, :size], %{size: SeenCache.size(seen)}, %{node_id: state.node_id})
    %{state | seen: seen}
  end

  defp default_node_id do
    {:node, node(), self()}
  end

  defp emit_sent(envelope, state, targets) do
    Telemetry.emit(
      [:message, :sent],
      message_measurements(envelope, state),
      Map.put(message_metadata(envelope, state), :targets, targets)
    )
  end

  defp emit_relay_result(:ok, envelope, state, targets, _failures) do
    Telemetry.emit(
      [:message, :relayed],
      message_measurements(envelope, state),
      Map.put(message_metadata(envelope, state), :targets, targets)
    )
  end

  defp emit_relay_result({:error, _reason}, _envelope, _state, _targets, _failures), do: :ok

  defp message_measurements(envelope, state) do
    %{
      bytes: byte_size(envelope.payload),
      ttl: envelope.ttl,
      seen_size: SeenCache.size(state.seen)
    }
  end

  defp message_metadata(envelope, state) do
    %{
      node_id: state.node_id,
      message_id: envelope.id,
      source: envelope.source,
      destination: envelope.destination
    }
  end

  defp peer_metadata(state, peer_id, transport, metadata) do
    %{node_id: state.node_id, peer_id: peer_id, transport: transport, metadata: metadata}
  end

  defp store_depth(state, destination) do
    state
    |> store_list()
    |> Map.get(destination, [])
    |> length()
  end

  defp store_put(state, destination, envelope),
    do: state.store_module.put(state.store, destination, envelope)

  defp store_list(state), do: state.store_module.list(state.store)
end

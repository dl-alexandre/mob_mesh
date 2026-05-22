defmodule Mob.Mesh.MeshBridge do
  @moduledoc """
  `Mob.Transport` implementation that turns point-to-point transports into a mesh.

  The bridge owns one or more underlying `Mob.Transport.Adapter` processes. It
  wraps outbound payloads in a small internal envelope, suppresses duplicate
  inbound mesh messages, delivers local payloads to its `:event_target`, and
  relays messages with epidemic flooding while TTL remains.
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
  @spec peers(GenServer.server()) :: map()
  def peers(mesh), do: GenServer.call(mesh, :peers)

  @doc false
  @spec stored(GenServer.server()) :: map()
  def stored(mesh), do: GenServer.call(mesh, :stored)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, event_target} <- fetch_event_target(opts),
         {:ok, transports} <- fetch_transports(opts),
         {:ok, discovery} <- Discovery.start_link([]),
         {:ok, store} <- Store.start_link(store_opts(opts)),
         {:ok, adapters} <- start_adapters(transports) do
      {:ok,
       %{
         node_id: Keyword.get_lazy(opts, :node_id, &default_node_id/0),
         event_target: event_target,
         adapters: adapters,
         peer_routes: %{},
         seen: SeenCache.new(Keyword.get(opts, :seen_limit, 4_096)),
         discovery: discovery,
         store: store
       }}
    end
  end

  @impl true
  def handle_call({:send_frame, destination, frame, opts}, _from, state) do
    envelope = Router.envelope(state.node_id, destination, frame, opts)
    {reply, state} = dispatch_or_store(envelope, state)
    {:reply, reply, remember(envelope.id, state)}
  end

  def handle_call({:broadcast_frame, frame, opts}, _from, state) do
    envelope = Router.envelope(state.node_id, :broadcast, frame, opts)
    {reply, state} = dispatch_or_store(envelope, state)
    {:reply, reply, remember(envelope.id, state)}
  end

  def handle_call(:peers, _from, state), do: {:reply, Discovery.peers(state.discovery), state}
  def handle_call(:stored, _from, state), do: {:reply, Store.list(state.store), state}

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    case adapter_by_pid(state.adapters, pid) do
      nil -> {:noreply, state}
      {name, _adapter} -> {:stop, {:transport_exit, name, reason}, state}
    end
  end

  def handle_info({:transport_up, peer_id, metadata}, state) do
    transport = transport_for_peer(metadata, state)
    :ok = Discovery.peer_up(state.discovery, transport, peer_id, metadata)

    state = put_peer_route(state, peer_id, transport, metadata)

    Telemetry.emit(
      [:peer, :discovered],
      %{count: 1},
      peer_metadata(state, peer_id, transport, metadata)
    )

    replay_stored(peer_id, state)
    send(state.event_target, {:transport_up, peer_id, metadata})

    {:noreply, state}
  end

  def handle_info({:transport_down, peer_id}, state) do
    :ok = Discovery.peer_down(state.discovery, peer_id)
    Telemetry.emit([:peer, :down], %{count: 1}, %{node_id: state.node_id, peer_id: peer_id})
    send(state.event_target, {:transport_down, peer_id})
    {:noreply, %{state | peer_routes: Map.delete(state.peer_routes, peer_id)}}
  end

  def handle_info({:frame, peer_id, frame}, state) do
    state = handle_inbound_frame(peer_id, frame, state)
    {:noreply, state}
  end

  def handle_info({:transport_error, reason}, state) do
    send(state.event_target, {:transport_error, reason})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_inbound_frame(peer_id, frame, state) do
    case decode(frame) do
      {:ok, %Envelope{} = envelope} ->
        handle_envelope(peer_id, envelope, state)

      :error ->
        send(state.event_target, {:frame, peer_id, frame})
        state
    end
  end

  defp handle_envelope(peer_id, envelope, state) do
    cond do
      SeenCache.member?(state.seen, envelope.id) ->
        state

      local_destination?(envelope, state) ->
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
        if reply != :ok, do: report_send_error(state, envelope, [{transport, peer_id, reply}])
        if reply == :ok, do: emit_sent(envelope, state, [{transport, peer_id}])
        {reply, state}

      {:flood, targets} ->
        {reply, failures} = flood_envelope(state, targets, envelope)
        if failures != [], do: report_send_error(state, envelope, failures)
        emit_relay_result(reply, envelope, state, targets, failures)
        {reply, state}

      :store ->
        :ok = Store.put(state.store, envelope.destination, envelope)

        Telemetry.emit([:message, :stored], message_measurements(envelope, state), %{
          node_id: state.node_id,
          message_id: envelope.id,
          destination: envelope.destination,
          queue_depth: store_depth(state.store, envelope.destination)
        })

        {:ok, state}
    end
  end

  defp replay_stored(peer_id, state) do
    state.store
    |> Store.pop(peer_id)
    |> Enum.each(fn envelope ->
      _ = dispatch_or_store(envelope, state)
    end)
  end

  defp send_envelope(state, transport, peer_id, envelope) do
    with {:ok, adapter} <- fetch_adapter(state, transport),
         {:ok, frame} <- encode(envelope) do
      Adapter.send_frame(adapter, peer_id, frame, [])
    end
  end

  defp flood_envelope(state, targets, envelope) do
    results =
      Enum.map(targets, fn {transport, peer_id} ->
        {transport, peer_id, send_envelope(state, transport, peer_id, envelope)}
      end)

    failures = Enum.reject(results, fn {_transport, _peer_id, result} -> result == :ok end)

    if Enum.any?(results, fn {_transport, _peer_id, result} -> result == :ok end) do
      {:ok, failures}
    else
      {{:error, {:no_successful_relay, results}}, failures}
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

    send(state.event_target, {:transport_error, reason})
  end

  defp encode(%Envelope{} = envelope) do
    {:ok, :erlang.term_to_binary({@magic, envelope})}
  end

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

  defp start_adapters(transports) do
    Enum.reduce_while(transports, {:ok, %{}}, fn transport_spec, {:ok, adapters} ->
      with {:ok, name, transport, opts} <- normalize_transport_spec(transport_spec),
           {:ok, pid} <- Adapter.start_link([transport: transport, event_target: self()] ++ opts) do
        {:cont, {:ok, Map.put(adapters, name, pid)}}
      else
        {:error, reason} -> {:halt, {:error, {:transport_start_failed, transport_spec, reason}}}
      end
    end)
  end

  defp normalize_transport_spec({name, transport}) when is_atom(name) and is_atom(transport),
    do: {:ok, name, transport, []}

  defp normalize_transport_spec({name, transport, opts})
       when is_atom(name) and is_atom(transport) and is_list(opts) do
    {:ok, name, transport, opts}
  end

  defp normalize_transport_spec(transport) when is_atom(transport),
    do: {:ok, transport, transport, []}

  defp normalize_transport_spec(other), do: {:error, {:invalid_transport_spec, other}}

  defp transport_for_peer(metadata, state) when is_map(metadata) do
    Map.get(metadata, :transport) || Map.get(metadata, "transport") || default_transport(state)
  end

  defp transport_for_peer(_metadata, state), do: default_transport(state)

  defp default_transport(state) do
    state.adapters |> Map.keys() |> List.first()
  end

  defp put_peer_route(state, peer_id, transport, metadata) do
    route = %{
      transport: transport,
      metadata: metadata,
      seen_at: System.monotonic_time(:millisecond)
    }

    %{state | peer_routes: Map.put(state.peer_routes, peer_id, route)}
  end

  defp fetch_adapter(state, transport) do
    case Map.fetch(state.adapters, transport) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, {:unknown_transport, transport}}
    end
  end

  defp adapter_by_pid(adapters, pid) do
    Enum.find(adapters, fn {_name, adapter} -> adapter == pid end)
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
    Telemetry.emit([:message, :sent], message_measurements(envelope, state), %{
      node_id: state.node_id,
      message_id: envelope.id,
      destination: envelope.destination,
      targets: targets
    })
  end

  defp emit_relay_result(:ok, envelope, state, targets, failures) do
    successful_targets =
      targets -- Enum.map(failures, fn {transport, peer_id, _reason} -> {transport, peer_id} end)

    Telemetry.emit([:message, :relayed], message_measurements(envelope, state), %{
      node_id: state.node_id,
      message_id: envelope.id,
      destination: envelope.destination,
      targets: successful_targets,
      failures: failures
    })
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

  defp store_depth(store, destination) do
    store
    |> Store.list()
    |> Map.get(destination, [])
    |> length()
  end
end

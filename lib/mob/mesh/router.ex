defmodule Mob.Mesh.Router do
  @moduledoc """
  Routing decisions for `Mob.Mesh.MeshBridge`.

  The first routing strategy is intentionally simple epidemic flooding with
  duplicate suppression and TTL. Direct peers are preferred for known unicast
  destinations; otherwise relayable messages are offered to every eligible
  neighbor.
  """

  alias Mob.Mesh.Router.Envelope

  defmodule Envelope do
    @moduledoc """
    Internal mesh envelope.
    """

    @enforce_keys [:id, :source, :destination, :payload]
    defstruct [:id, :source, :destination, :payload, ttl: 8, path: []]

    @type t :: %__MODULE__{
            id: binary(),
            source: term(),
            destination: term(),
            payload: binary(),
            ttl: non_neg_integer(),
            path: [term()]
          }
  end

  @type peer_id :: term()
  @type transport_name :: atom()
  @type peer_route :: %{transport: transport_name(), metadata: term(), seen_at: integer()}
  @type route_decision ::
          {:direct, transport_name(), peer_id()}
          | {:flood, [{transport_name(), peer_id()}]}
          | :store

  @doc """
  Builds a new outbound envelope.
  """
  @spec envelope(term(), peer_id(), binary(), keyword()) :: Envelope.t()
  def envelope(source, destination, payload, opts \\ []) when is_binary(payload) do
    %Envelope{
      id: Keyword.get_lazy(opts, :message_id, &message_id/0),
      source: source,
      destination: destination,
      payload: payload,
      ttl: Keyword.get(opts, :ttl, 8),
      path: [source]
    }
  end

  @doc """
  Chooses the next hop or hops for an envelope.
  """
  @spec route(Envelope.t(), %{optional(peer_id()) => peer_route()}, keyword()) :: route_decision()
  def route(%Envelope{destination: destination}, peer_routes, opts \\ []) do
    excluded = Keyword.get(opts, :exclude, MapSet.new())

    cond do
      Map.has_key?(peer_routes, destination) and not MapSet.member?(excluded, destination) ->
        %{transport: transport} = Map.fetch!(peer_routes, destination)
        {:direct, transport, destination}

      true ->
        flood = flood_targets(peer_routes, excluded)
        if flood == [], do: :store, else: {:flood, flood}
    end
  end

  @doc """
  Returns whether an envelope can be relayed again.
  """
  @spec relayable?(Envelope.t()) :: boolean()
  def relayable?(%Envelope{ttl: ttl}), do: ttl > 0

  @doc """
  Marks a relay hop and decrements TTL.
  """
  @spec relay(Envelope.t(), term()) :: Envelope.t()
  def relay(%Envelope{} = envelope, node_id) do
    %Envelope{
      envelope
      | ttl: max(envelope.ttl - 1, 0),
        path: Enum.uniq([node_id | envelope.path])
    }
  end

  defp flood_targets(peer_routes, excluded) do
    peer_routes
    |> Enum.reject(fn {peer_id, _route} -> MapSet.member?(excluded, peer_id) end)
    |> Enum.map(fn {peer_id, %{transport: transport}} -> {transport, peer_id} end)
  end

  defp message_id do
    Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end
end

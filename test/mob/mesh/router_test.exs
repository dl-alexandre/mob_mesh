defmodule Mob.Mesh.RouterTest do
  use ExUnit.Case, async: true

  alias Mob.Mesh.Router

  test "routes directly when destination is a known peer" do
    envelope = Router.envelope(:a, :b, "hello")
    peer_routes = %{b: %{transport: :ble, metadata: %{}, seen_at: 0}}

    assert Router.route(envelope, peer_routes) == {:direct, :ble, :b}
  end

  test "falls back to flooding when destination route is unknown" do
    envelope = Router.envelope(:a, :z, "hello")

    peer_routes = %{
      b: %{transport: :ble, metadata: %{}, seen_at: 0},
      c: %{transport: :wifi, metadata: %{}, seen_at: 0}
    }

    assert {:flood, targets} = Router.route(envelope, peer_routes)
    assert Enum.sort(targets) == [ble: :b, wifi: :c]
  end

  test "stores when there are no eligible next hops" do
    envelope = Router.envelope(:a, :z, "hello")

    assert Router.route(envelope, %{}) == :store
  end
end

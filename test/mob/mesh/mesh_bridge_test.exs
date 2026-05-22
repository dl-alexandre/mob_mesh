defmodule Mob.Mesh.MeshBridgeTest do
  use ExUnit.Case, async: true

  alias Mob.Mesh.MeshBridge

  test "implements the Mob.Transport bridge API and sends to direct peers" do
    {:ok, bridge} =
      MeshBridge.start_link(
        event_target: self(),
        node_id: :node_a,
        transports: [{:ble, Mob.Mesh.FakeTransport, transport_opts: [owner: self()]}]
      )

    send(bridge, {:transport_up, :node_b, %{transport: :ble}})

    assert_receive {:transport_up, :node_b, %{transport: :ble}}
    assert :ok = MeshBridge.send_frame(bridge, :node_b, "hello", ttl: 2)
    assert_receive {:fake_transport_send, :node_b, frame, []}

    send(bridge, {:frame, :node_b, frame})
    refute_receive {:frame, :node_a, "hello"}, 50
  end

  test "stores outbound messages when no route exists and replays when peer appears" do
    {:ok, bridge} =
      MeshBridge.start_link(
        event_target: self(),
        node_id: :node_a,
        transports: [{:ble, Mob.Mesh.FakeTransport, transport_opts: [owner: self()]}]
      )

    assert :ok = MeshBridge.send_frame(bridge, :node_b, "queued", [])
    assert %{node_b: [_envelope]} = MeshBridge.stored(bridge)

    send(bridge, {:transport_up, :node_b, %{transport: :ble}})

    assert_receive {:transport_up, :node_b, %{transport: :ble}}
    assert_receive {:fake_transport_send, :node_b, _frame, []}
    assert %{} = MeshBridge.stored(bridge)
  end

  test "delivers mesh envelopes addressed to the local node" do
    {:ok, node_a} =
      MeshBridge.start_link(
        event_target: self(),
        node_id: :node_a,
        transports: [{:ble, Mob.Mesh.FakeTransport, transport_opts: [owner: self()]}]
      )

    {:ok, node_b} =
      MeshBridge.start_link(
        event_target: self(),
        node_id: :node_b,
        transports: [{:ble, Mob.Mesh.FakeTransport, transport_opts: [owner: self()]}]
      )

    send(node_a, {:transport_up, :node_b, %{transport: :ble}})
    assert_receive {:transport_up, :node_b, %{transport: :ble}}

    assert :ok = MeshBridge.send_frame(node_a, :node_b, "hello", [])
    assert_receive {:fake_transport_send, :node_b, frame, []}

    send(node_b, {:frame, :node_a, frame})
    assert_receive {:frame, :node_a, "hello"}
  end
end

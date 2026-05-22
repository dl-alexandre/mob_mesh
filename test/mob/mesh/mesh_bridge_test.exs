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

  test "emits transport errors when a direct send fails" do
    {:ok, bridge} =
      MeshBridge.start_link(
        event_target: self(),
        node_id: :node_a,
        transports: [
          {:ble, Mob.Mesh.FakeTransport,
           transport_opts: [owner: self(), send_reply: {:error, :offline}]}
        ]
      )

    send(bridge, {:transport_up, :node_b, %{transport: :ble}})
    assert_receive {:transport_up, :node_b, %{transport: :ble}}

    assert {:error, :offline} = MeshBridge.send_frame(bridge, :node_b, "hello", [])

    assert_receive {:transport_error,
                    {:mesh_send_failed, _message_id, [{:ble, :node_b, {:error, :offline}}]}}
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

  test "can be used as a child in a supervision tree" do
    {:ok, supervisor} =
      Supervisor.start_link(
        [
          {MeshBridge,
           event_target: self(),
           node_id: :node_a,
           transports: [{:ble, Mob.Mesh.FakeTransport, transport_opts: [owner: self()]}]}
        ],
        strategy: :one_for_one
      )

    [{_, bridge, _, _}] = Supervisor.which_children(supervisor)
    assert is_pid(bridge)
  end
end

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
    attach_telemetry([[:mob_mesh, :message, :stored], [:mob_mesh, :peer, :discovered]])

    {:ok, bridge} =
      MeshBridge.start_link(
        event_target: self(),
        node_id: :node_a,
        transports: [{:ble, Mob.Mesh.FakeTransport, transport_opts: [owner: self()]}]
      )

    assert :ok = MeshBridge.send_frame(bridge, :node_b, "queued", [])
    assert_receive {:telemetry_event, [:mob_mesh, :message, :stored], %{bytes: 6}, metadata}
    assert %{node_id: :node_a, destination: :node_b, queue_depth: 1} = metadata
    assert %{node_b: [_envelope]} = MeshBridge.stored(bridge)

    send(bridge, {:transport_up, :node_b, %{transport: :ble}})

    assert_receive {:telemetry_event, [:mob_mesh, :peer, :discovered], %{count: 1},
                    %{node_id: :node_a, peer_id: :node_b, transport: :ble}}

    assert_receive {:transport_up, :node_b, %{transport: :ble}}
    assert_receive {:fake_transport_send, :node_b, _frame, []}
    assert %{} = MeshBridge.stored(bridge)
  end

  test "supports a custom store backend" do
    {:ok, bridge} =
      MeshBridge.start_link(
        event_target: self(),
        node_id: :node_a,
        store: Mob.Mesh.FakeStore,
        store_opts: [owner: self()],
        transports: [{:ble, Mob.Mesh.FakeTransport, transport_opts: [owner: self()]}]
      )

    assert :ok = MeshBridge.send_frame(bridge, :node_b, "queued", [])
    assert_receive {:fake_store_put, :node_b, _envelope}
    assert %{node_b: [_envelope]} = MeshBridge.stored(bridge)

    send(bridge, {:transport_up, :node_b, %{transport: :ble}})

    assert_receive {:fake_store_pop, :node_b}
    assert_receive {:fake_transport_send, :node_b, _frame, []}
  end

  test "emits transport errors when a direct send fails" do
    attach_telemetry([[:mob_mesh, :message, :error]])

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

    assert_receive {:telemetry_event, [:mob_mesh, :message, :error], %{count: 1},
                    %{node_id: :node_a, destination: :node_b}}
  end

  test "delivers mesh envelopes addressed to the local node" do
    attach_telemetry([[:mob_mesh, :message, :sent], [:mob_mesh, :message, :delivered]])

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
    assert_receive {:telemetry_event, [:mob_mesh, :message, :sent], %{bytes: 5}, metadata}
    assert %{node_id: :node_a, destination: :node_b, targets: [ble: :node_b]} = metadata

    send(node_b, {:frame, :node_a, frame})
    assert_receive {:frame, :node_a, "hello"}

    assert_receive {:telemetry_event, [:mob_mesh, :message, :delivered], %{bytes: 5},
                    %{node_id: :node_b, source: :node_a, destination: :node_b}}
  end

  test "emits relay telemetry for flooded multi-hop sends" do
    attach_telemetry([[:mob_mesh, :message, :relayed]])

    {:ok, bridge} =
      MeshBridge.start_link(
        event_target: self(),
        node_id: :node_a,
        transports: [{:ble, Mob.Mesh.FakeTransport, transport_opts: [owner: self()]}]
      )

    send(bridge, {:transport_up, :node_b, %{transport: :ble}})
    send(bridge, {:transport_up, :node_c, %{transport: :ble}})
    assert_receive {:transport_up, :node_b, %{transport: :ble}}
    assert_receive {:transport_up, :node_c, %{transport: :ble}}

    assert :ok = MeshBridge.send_frame(bridge, :node_z, "flood", ttl: 2)

    assert_receive {:fake_transport_send, :node_b, _frame_b, []}
    assert_receive {:fake_transport_send, :node_c, _frame_c, []}

    assert_receive {:telemetry_event, [:mob_mesh, :message, :relayed], %{bytes: 5},
                    %{node_id: :node_a, destination: :node_z, targets: targets}}

    assert Enum.sort(targets) == [ble: :node_b, ble: :node_c]
  end

  test "relays a unicast message across three mesh nodes" do
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

    {:ok, node_c} =
      MeshBridge.start_link(
        event_target: self(),
        node_id: :node_c,
        transports: [{:ble, Mob.Mesh.FakeTransport, transport_opts: [owner: self()]}]
      )

    send(node_a, {:transport_up, :node_b, %{transport: :ble}})
    send(node_b, {:transport_up, :node_c, %{transport: :ble}})
    assert_receive {:transport_up, :node_b, %{transport: :ble}}
    assert_receive {:transport_up, :node_c, %{transport: :ble}}

    assert :ok = MeshBridge.send_frame(node_a, :node_c, "multi-hop", ttl: 3)
    assert_receive {:fake_transport_send, :node_b, frame_ab, []}

    send(node_b, {:frame, :node_a, frame_ab})
    assert_receive {:fake_transport_send, :node_c, frame_bc, []}

    send(node_c, {:frame, :node_b, frame_bc})
    assert_receive {:frame, :node_a, "multi-hop"}
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

  defp attach_telemetry(events) do
    test_pid = self()
    ref = make_ref()

    :ok =
      :telemetry.attach_many(
        "mesh-bridge-test-#{inspect(ref)}",
        events,
        &__MODULE__.handle_telemetry/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach("mesh-bridge-test-#{inspect(ref)}") end)
  end

  def handle_telemetry(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end
end

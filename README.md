# mob_mesh

`mob_mesh` is the multi-hop mesh transport layer for the `mob` ecosystem. It
sits above point-to-point transport plugins such as `mob_ble` or future WiFi
plugins and exposes its own `Mob.Transport` bridge.

The initial implementation provides:

- `Mob.Mesh.MeshBridge`, a `Mob.Transport` implementation.
- Basic epidemic flooding with TTL.
- Duplicate suppression.
- Process-local store-and-forward queue for offline destinations.
- Discovery state for peers learned from underlying transports.

## Usage

```elixir
{:ok, mesh} =
  Mob.Mesh.start_link(
    event_target: self(),
    node_id: "device-a",
    transports: [
      {:ble, Mob.Ble.MobileBridge, transport_opts: [some: :option]}
    ]
  )

:ok = Mob.Mesh.send_message(mesh, "device-b", "hello")
```

Applications using `Mob.Transport.Adapter` can wrap `Mob.Mesh.bridge_module()`
like any other transport implementation.

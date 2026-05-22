# Migration

`mob_mesh` depends on `mob_transport` rather than concrete carriers.

To migrate a point-to-point transport into the mesh:

1. Ensure the carrier implements `Mob.Transport`.
2. Start `Mob.Mesh.MeshBridge` with the carrier in `:transports`.
3. Send application payloads to the mesh bridge instead of the carrier bridge.
4. Listen for canonical `Mob.Transport` events from the mesh bridge.
5. For durable mobile delivery, pass a module implementing
   `Mob.Mesh.Store.Behaviour` with the bridge's `:store` option.

The bridge currently uses an internal Erlang-term envelope between mesh nodes.
That format is private and should be replaced with a stable wire envelope before
cross-version compatibility is required.

Use telemetry during migration to compare direct transport delivery with mesh
delivery:

- `[:mob_mesh, :message, :sent]`
- `[:mob_mesh, :message, :relayed]`
- `[:mob_mesh, :message, :stored]`
- `[:mob_mesh, :message, :error]`

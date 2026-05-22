# Performance

The initial routing strategy is epidemic flooding. It is useful for early
multi-hop behavior because it does not require global topology knowledge, but it
can spend bandwidth and battery quickly in dense mobile meshes.

Current controls:

- `:ttl` on outbound sends limits relay depth.
- `:seen_limit` bounds duplicate-suppression memory.
- `:store_opts` can cap the in-memory store queue.

Mobile guidance:

- Use small TTL values for BLE-heavy networks.
- Prefer direct transport sends when multi-hop delivery is not needed.
- Keep payloads compact; the mesh layer does not fragment or compress.
- Tune BLE scan/advertising behavior in the underlying transport, not in
  `mob_mesh`.

Planned improvements include telemetry, configurable fan-out, probabilistic
forwarding, and routing scores based on metadata such as link quality or battery
state.

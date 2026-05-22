# Security

`mob_mesh` currently provides routing, duplicate suppression, and
store-and-forward behavior. It does not authenticate peers, sign messages, or
encrypt payloads by itself.

Production applications should treat the current mesh envelope as an untrusted
transport container:

- Sign or encrypt application payloads before calling `Mob.Mesh.send_message/4`.
- Use stable node IDs derived from trusted device identity, such as a persisted
  UUID paired with an application-level key or a public-key fingerprint.
- Validate authorization at the application layer before accepting a delivered
  payload.
- Consider replay protection above the mesh layer for security-sensitive
  messages. The bridge's seen cache is a routing duplicate-suppression window,
  not a cryptographic replay defense.

Future work should add an optional signing/encryption envelope once the mob
identity and key-management model is stable.

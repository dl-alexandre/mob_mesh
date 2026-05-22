# Routing Strategy

The first `mob_mesh` router uses epidemic flooding:

- If the destination is a known direct peer, send to that peer.
- If the destination is not known, forward to every eligible peer.
- Every mesh envelope carries a TTL.
- Every bridge keeps a bounded seen-message set for duplicate suppression.
- The inbound peer and peers already in the envelope path are excluded from relay.

This keeps the first implementation deterministic and easy to test. Later
strategies can keep the same router boundary and add route scoring, Spray and
Wait, PRoPHET-style delivery probabilities, or battery/bandwidth policies.

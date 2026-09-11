# Authenticate automation messages received over Rednet

## Summary

Factory and RS Store currently trust incoming snapshots based only on their
Rednet protocol name. Any computer on the same Rednet network can send a table
using that public protocol and replace the data shown by either dashboard.

Hub already applies the minimum sender check that the other dashboards are
missing: it requires both the expected protocol and the configured computer ID
before accepting a snapshot. This should become a shared trust-boundary rule
for every automation app, followed by message authentication for deployments
where untrusted computers can join the network.

## Why this matters

These dashboards are an operator interface for automation, including emergency
stop, device toggle, and reboot controls. A forged snapshot can make a stopped
or stale system appear healthy, show misleading inventory levels, or populate
computer/device data that leads an operator to act on the wrong target.

Checking a protocol string is not authentication: protocol names are catalog
metadata and can be copied by any Rednet peer. Checking the configured sender
ID prevents accidental cross-talk and simple spoofing, but does not protect
against an attacker that can forge or relay Rednet traffic. The security model
and its limitations therefore need to be explicit.

## Current behavior

- `factory.lua` accepts any `snapshot` table when the protocol matches
  `dashboardProtocol`; it does not compare the event's sender ID with
  `masterComputer`.
- `storage.lua` and `storage.dev.lua` accept any normalizable snapshot when the
  protocol matches `rsProtocol`; they do not compare the sender with
  `rsComputer`.
- `hub.lua` and `hub.dev.lua` are the safer reference: both require the expected
  protocol, sender ID, message table, and message type.
- Outbound control paths also rely on plain Rednet messages, so inbound sender
  filtering alone is only the first hardening step.

## Proposed work

1. Add a shared message-validation helper in MineboomOS that checks sender ID,
   protocol, message type, and a versioned envelope before payloads reach an
   app.
2. Update Factory and both RS Store variants to reject messages whose sender ID
   differs from the configured peer. Keep production and development variants
   behaviorally identical.
3. Define an authentication option for control and snapshot messages (for
   example, a per-installation secret plus nonce and MAC), including replay
   protection and secret rotation. Do not present sender-ID filtering as
   cryptographic authentication.
4. Validate configured computer IDs at startup. When a trusted peer is not
   configured, show a clear configuration error rather than accepting any
   sender.
5. Add rate-limited diagnostics for rejected messages without logging secrets
   or full sensitive payloads.
6. Document the threat model, setup, migration path, and compatibility behavior
   for older MineboomOS peers.

## Acceptance criteria

- Factory, RS Store, and Hub accept snapshots only from their configured peer,
  on the configured protocol, with the expected message type and supported
  envelope version.
- Forged messages with the correct protocol but a different sender do not
  mutate UI state or freshness timestamps.
- Missing or invalid trusted-peer configuration fails closed and gives the
  operator an actionable error.
- Destructive commands (emergency stop, device toggle, and reboot) use the
  documented authenticated envelope when authentication is enabled.
- Replayed, expired, malformed, and incorrectly authenticated messages are
  rejected.
- Automated tests cover valid traffic, wrong sender, wrong protocol, wrong
  type/version, invalid authentication, and replay attempts for production and
  development app variants.
- The catalog/OS documentation states whether a deployment is using only
  sender filtering or full message authentication.

## Dependencies and rollout notes

The reusable validator and authenticated envelope belong in MineboomOS because
application modules receive networking through the OS context. Roll out
receiver support before requiring the new envelope, provide a bounded migration
window if legacy peers must remain usable, and remove compatibility mode once
all automation computers have been upgraded.

Until this work is complete, automation Rednet networks should be treated as
trusted networks and should not include computers controlled by untrusted
players.

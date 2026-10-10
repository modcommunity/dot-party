# dot-party

Parties that play together, from both ends of the TMC backbone's party system: the player's client (manage, ready up, follow the party to its server) and the game server (track, report, enforce a booking). A local hub runs the site's rules in-process for LAN, offline and the suite.

Read the family [CLAUDE.md](../../CLAUDE.md) first, and [docs/backbone.md](../../docs/backbone.md) for anything that talks to website-city.

**The distributable is `addons/dot_party/`.** It requires [dot-core](../dot-core) and nothing else (`ln -s ../../dot-core/addons/dot_core addons/dot_core`, gitignored). dot-auth's clients and dot-server's admission seam are reached by duck typing and never named.

## Read before

| Read | Before |
| --- | --- |
| [docs/backbone-contract.md](docs/backbone-contract.md) | changing a request or response: every route, its scope, shape, rate limit and app scoping |
| [docs/design.md](docs/design.md) | anything else: the two halves, the pieces, refusal keys, the hub's rule order, polling, following, kicks, bookings, the state report |
| [docs/history.md](docs/history.md) | the parse failure, the invented keys, dot-auth's refusal shape, the ready round that never followed |

## Layout

| Path | What |
| --- | --- |
| `core/` | `DotParty`, `DotPartyMember`, `DotPartyReady`, `DotPartyReservation`, `DotPartyReservePolicy` |
| `backend/` | `DotPartyBackend` (interface), `DotPartyBackendApp` (the site), `DotPartyLocalHub` + `DotPartyBackendLocal` (in-process) |
| `runtime/dot_party_client.gd` | `DotPartyClient`: the player's node |
| `server/dot_party_server.gd` | `DotPartyServer`: claims, rosters, state report, `party_of(uid)` |
| `server/dot_party_reservations.gd` | `DotPartyReservations`: booking enforcement as `dot_ban_source` |
| `dot_party_config.gd` | `DotPartyConfig`: poll, heartbeat, state-report and reservation-sync intervals |
| `examples/party_selftest.tscn` | the suite, no network |

Paths except `examples/` are in `addons/dot_party/`.

## Running and testing

The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `timeout 120 godot --headless --path . res://examples/party_selftest.tscn`. `_test_reservations` is the section to keep: a private booking admits only its party and still honours the ban list behind it, a public one holds seats while the party loads, and an outage leaves the booking in force. The suite cannot see differences between the local hub and the real site; a change to a request shape wants a run against a dev site.

## Rules that bite

- A party id is a decimal string, never a number (JSON rounds past 2^53). [design](docs/design.md#the-pieces)
- Every backend method may await; call them all with `await`. [design](docs/design.md#the-pieces)
- Refusal keys are the site's, read from its locale files; never invent one where the site has one. [design](docs/design.md#refusals-are-the-sites-keys)
- The local hub and reserve policy copy the site's rules in the site's order; a rule change on the site needs the same change here. [design](docs/design.md#the-local-hub-is-the-sites-rules-in-the-sites-order)
- Heartbeat under the site's 150 s staleness (`validate()` refuses otherwise); do not poll `party/mine` faster than 1.5 s. [design](docs/design.md#the-client-polls-because-the-site-pushes-nothing), [contract](docs/backbone-contract.md#the-players-half)
- `connect_requested` fires once per round; LOBBY or SEARCHING resets it. The connect address comes from the ready view, not the snapshot. [design](docs/design.md#following-is-once-per-round-reset-by-the-lobby)
- A game token reaches only its own app's parties (`party.deny.otherApp`). [contract](docs/backbone-contract.md#the-players-half)
- Bookings admit through `dot_ban_source`, chain the previous holder and restore it on exit; members match by `backbone:<userId>`, never by name; an outage keeps the booking. [design](docs/design.md#a-booking-admits-through-the-ban-seam-chained-and-hands-it-back)
- The state report is the whole list every time and never carries a uid. [design](docs/design.md#the-state-report-is-absolute-and-never-carries-a-uid)
- Never name a method after an `Object` method (`is_connected`). [history](docs/history.md#is_connected-shadowed-objectis_connected)

Deliberately not here: the site's routes, a party UI, party voice or chat (dot-chat's grouped channel), the server finder. [design](docs/design.md#deliberately-not-here)

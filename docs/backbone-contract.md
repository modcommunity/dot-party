# The backbone contract

What dot-party speaks, split into the routes website-city **already serves** and the routes it **needs to add**. Every added route is a thin wrapper over a function the site already has, and uses that function's own input names, so the site-side work is plumbing rather than design.

## Already served — the game server's half

Under `/api/integration/v1`, authenticated by an integration credential (`Authorization: Bearer tmci_…`), stamped with `ts` (Unix **seconds**) and a `nonce`. dot-auth's `DotBackboneClient.post_integration` / `get_integration` does the stamping; `DotPartyServer` calls them by name.

| Route | Scope | Used by |
| --- | --- | --- |
| `GET party/{id}` | `PARTY_READ` | `DotPartyServer.claim`, `refresh` |
| `POST party/state` | `PARTY_STATE` | `DotPartyServer.report_state` — the absolute player list, every 15 s |
| `POST party/session` | `PARTY_SESSION` | `player_joined`, `player_left` |
| `POST party/match` | `PARTY_STATE` + `PARTY_STATS` | `match_started`, `match_ended` |
| `POST party/create` | `PARTY_WRITE` | `create_party` (PUBLIC or FRIENDS only) |
| `POST party/end` | `PARTY_WRITE` | `end_party` |

Shapes are the site's, documented in `website-city/docs/api/integration-api.md`. dot-party's suite parses the `GET party/{id}` example from that document verbatim.

## To add — a game server learning it has been booked

The site's own audit: *"a private (locked) reservation is never sent to the game server through any integration endpoint."* This is the one route that closes that gap.

### `GET /api/integration/v1/party/reservation` — scope `PARTY_READ`, server-scoped credential

The booking this server is under right now, and who it is for. The server is the credential's server; nothing in the request names one.

```json
{
  "ok": true,
  "reservation": {
    "id": "88", "partyId": "4471", "serverId": 4821, "status": "ACTIVE", "private": true,
    "startsAt": "2026-09-23T20:00:00.000Z", "endsAt": "2026-09-23T22:00:00.000Z",
    "requestedById": "clx…", "note": null
  },
  "party": { "id": "4471", "name": "Scrim", "maxUsers": 10, "hostId": "clx…", "endTime": null },
  "members": [ { "userId": "clx…", "displayName": "Ashley", "role": "HOST" } ]
}
```

`reservation: null` when there is none. Only `ACTIVE` bookings whose window contains now. Implementation: `GetActiveReservation` in `src/lib/party/reserve.ts` plus the party's JOINED members, un-anonymised for the same reason `GET party/{id}` is — the server's job is to recognise them. `DotPartyReservations.use_backbone(client)` polls it every 30 s and parses it with `parse_backbone`.

**Why members carry `userId`:** a dot-server session's uid after dot-auth is `backbone:<userId>`. Matching on display names would let a stranger in by calling themselves the host.

## To add — the player's half

Under `/api/app/v1`, authenticated by the player's app token (`Authorization: Bearer <AppToken>`), in the app API's envelope: `{ ok: true, data }` or `{ ok: false, code, message, retryAfter? }` (`src/types/app-api/contract.ts`). For a refusal, `code` is the site's i18n key — `party.join.deny.full` — exactly as the tRPC procedures already throw it. Each route must allow `GAME` tokens (`allowGame`), because that is the token a game holds.

| Route | Wraps | Body / query | `data` |
| --- | --- | --- | --- |
| `GET party/mine` | `membership.mine` | — | the party (as `GET party/{id}` shapes it, flat, with `members` and `stage`) or `null` |
| `GET party/{id}` | `view.get` | — | the party. Must include the caller's own row even if they are no longer JOINED, so a client can tell "you were kicked" from "you left" |
| `POST party/create` | `CreateOrSaveParty` | `CreatePartyInput` | the party |
| `POST party/join` | `JoinParty` | `{ id, password?, token? }` | `{ partyId, role, leftPartyId }` |
| `POST party/leave` | `LeaveParty` | `{ id, silent? }` | `{ left, ended }` |
| `POST party/heartbeat` | `membership.heartbeat` | `{ id }` | `null` |
| `POST party/kick` | `membership.kick` | `{ id, userId, ban }` | `null` |
| `POST party/role` | `membership.setRole` | `{ id, userId, role }` | `null` |
| `POST party/transfer` | `create.transferHost` | `{ id, userId }` | `null` |
| `POST party/invite` | `invite.create` | `{ id, userIds[1..25], message? }` | invite ids |
| `GET party/invites` | `invite.mine` | — | `[{ id, partyId, partyName, inviterId, message }]` |
| `POST party/invite/respond` | `invite.respond` | `{ inviteId, accept }` | as `join` when accepted |
| `POST party/start` | `search.start` with `useCurrentServer`, or `setServer` then open READY | `{ id, serverId? }` | `PartyReadyView` |
| `GET party/{id}/ready` | `ready.state` | — | `PartyReadyView` |
| `POST party/ready` | `ready.setReady` | `{ id, ready }` | `PartyReadyView` |
| `POST party/connected` | `ready.connected` | `{ id }` | `null` |
| `POST party/force-start` | `ready.forceStart` | `{ id }` | `null` |
| `POST party/cancel` | `ready.cancel` | `{ id }` | `null` |
| `POST party/end` | `EndParty` | `{ id }` | `null` |
| `GET party/{id}/reserve/offer?serverId=` | `ServerReservationOffer` | — | `ReserveOffer` |
| `POST party/reserve` | `ReserveServerForParty` | `ReserveServerInput` | the reservation |
| `POST party/reserve/cancel` | `reserve.cancel` | `{ reservationId }` | the reservation |

Rate limits should be the tRPC procedures' own (`join` 30/5 min, `reserve.request` 10/5 min, `search.start` 20/5 min).

### Why the connect URL matters

`PartyReadyView.connect.url` is the site's resolved connect template for the app. `DotPartyClient` hands it to the game's `connect_fn` once per ready round and then calls `party/connected`, which is what lets the site start the round the moment the last member is in.

## What dot-party duplicates on purpose

`DotPartyReservePolicy` is `ServerReservationOffer`, `ReserveWindowOpen` and `ReserveWindowCloses`, ported line for line, including the wrapped window (22:00 → 02:00) and clamping rather than refusing a booking that would run past the window. `DotPartyLocalHub` is `CanJoinParty` in the site's order (ended, banned, alreadyIn, the host always gets back in, full, type, the after-start lock for walk-ins only) and the ready round's arm-once / disarm-below-threshold rule.

They are copies for the reason dot-stats' merge rule is: a LAN server with no website still has to answer these questions, and two implementations that disagree about a booking window mean a party turned away from a server the site said was theirs. **A change to any of these rules on the site needs the same change here**, and the suite section that covers it.

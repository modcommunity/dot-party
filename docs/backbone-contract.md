# The backbone contract

What dot-party speaks: the game server's half under `/api/integration/v1/party/`, and the player's half under `/api/app/v1/party/`. Every route below is served by website-city `main` (checked against `src/app/api/integration/v1/party/` and `src/app/api/app/v1/party/`); whether a given site is deployed with it cannot be known from here. Every player-side route and the reservation route are thin wrappers over a function the site already had, using that function's own input names, so a contract change starts on the site.

## The game server's half

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

## A game server learning it has been booked

Without this route a private (locked) reservation was never sent to the game server through any integration endpoint, so a server meant to hold its slots for a party had no way to learn which party.

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

`reservation: null` when there is none. Only `ACTIVE` bookings whose window contains now (`GetActiveReservation` alone answers "ends in the future", which would also match a booking approved for later). Built from `GetActiveReservation` in `src/lib/party/reserve.ts` plus the party's JOINED members, un-anonymised for the same reason `GET party/{id}` is — the server's job is to recognise them. `DotPartyReservations.use_backbone(client)` polls it every 30 s and parses it with `parse_backbone`.

**Why members carry `userId`:** a dot-server session's uid after dot-auth is `backbone:<userId>`. Matching on display names would let a stranger in by calling themselves the host.

## The player's half

Under `/api/app/v1`, authenticated by the player's app token (`Authorization: Bearer <AppToken>`), in the app API's envelope: `{ ok: true, data }` or `{ ok: false, code, message, retryAfter? }` (`src/types/app-api/contract.ts`). For a refusal, `code` is the site's i18n key — `party.join.deny.full` — exactly as the tRPC procedures already throw it. Each route allows `GAME` tokens (`HandleAppGameAction` sets `allowGame`), because that is the token a game holds. **A `GAME` credential reaches only its own app's parties** (`AssertPartyInGameApp` in `src/lib/party/app-view.ts`): a party in another game is refused with `party.deny.otherApp`. A device credential is bound to no app and is not narrowed.

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

Rate limits are the website's own buckets (`PARTY_LIMITS` in `src/lib/party/limits.ts`, e.g. `join` 30 / 300 s, `reserve` 10 / 300 s, `start` 20 / 300 s), shared with the website so alternating surfaces buys no extra attempts. `GET party/mine` has a bucket of its own (`PARTY_APP_MINE_LIMIT`, 600 / 300 s) sized for three clients on one account polling the ready round at `PARTY_APP_MINE_POLL_SEC` (1.5 s), which is `DotPartyConfig.ready_poll_sec`; a faster client poll runs a second install into 429s mid-round.

### Why the connect URL matters

`PartyReadyView.connect.url` is the site's resolved connect template for the app. `DotPartyClient` hands it to the game's `connect_fn` once per ready round and then calls `party/connected`, which is what lets the site start the round the moment the last member is in. **The party snapshot does not carry it**: `GET party/mine` and `GET party/{id}` have no `connect`, because the address is only built for a JOINED member in the ready view. So `DotPartyClient.refresh` asks `GET party/{id}/ready` whenever the snapshot is READY with no address — without that it never followed a round against the real site, which the suite driving the local hub (whose snapshot does carry it) could not see.

## What dot-party duplicates on purpose

`DotPartyReservePolicy` is `ServerReservationOffer`, `ReserveWindowOpen` and `ReserveWindowCloses`, ported line for line, including the wrapped window (22:00 → 02:00) and clamping rather than refusing a booking that would run past the window. `DotPartyLocalHub` is `CanJoinParty` in the site's order (ended, banned, alreadyIn, the host always gets back in, full, type, the after-start lock for walk-ins only) and the ready round's arm-once / disarm-below-threshold rule.

They are copies for the reason dot-stats' merge rule is: a LAN server with no website still has to answer these questions, and two implementations that disagree about a booking window mean a party turned away from a server the site said was theirs. **A change to any of these rules on the site needs the same change here**, and the suite section that covers it.

# Design

Why dot-party is shaped the way it is. The routes are in [backbone-contract.md](backbone-contract.md); the one-line rules are in [CLAUDE.md](../CLAUDE.md).

## Two halves of the site's party system

website-city has a complete party system (`Party`, `PartyMember`, invites, a ready round, a server finder, reservations with owner terms). dot-party speaks both ends of it:

| | Site routes | Here |
| --- | --- | --- |
| The **game server** tracking a party | `/api/integration/v1/party/{id,state,session,match,create,end}` | `DotPartyServer` |
| The **game server** learning it is booked | `/api/integration/v1/party/reservation` | `DotPartyReservations` |
| The **player** managing their party | `/api/app/v1/party/*` (before these, only tRPC behind the website's session cookie, which a game client does not hold) | `DotPartyBackendApp` |

game-arena's `arena_party.gd` and its siblings are peer-to-peer sessions over dot-peer-to-peer: a different thing that shares the word.

## The pieces

| | |
| --- | --- |
| `DotParty`, `DotPartyMember` | The site's party and member, field for field. The id is a decimal **string**, because JSON rounds past 2^53 and the rounded id names somebody else's party. |
| `DotPartyReady` | The site's `PartyReadyView`. |
| `DotPartyReservation`, `DotPartyReservePolicy` | A booking, and an owner's terms: `ServerReservationOffer` ported line for line. |
| `DotPartyBackend` | The interface. Every method may await; call them all with `await`. |
| `DotPartyBackendApp` | The site as the player, through dot-auth's `post_app` / `get_app` (preferred) or a token and a `DotHttp`. |
| `DotPartyLocalHub`, `DotPartyBackendLocal` | The site's rules in-process: LAN, offline, suites. One hub, one backend per person. |
| `DotPartyClient` | The player's node: polls, heartbeats, diffs snapshots into signals, follows the party to its server. |
| `DotPartyServer` | The server's node: claims, rosters, the absolute state report, sessions, rounds; `party_of(uid)`. |
| `DotPartyReservations` | The server's node that enforces a booking through `dot_ban_source`, chained. |

## Refusals are the site's keys

`DotError.detail` carries `party.join.deny.full`, `party.reserve.deny.window` and so on, from every backend. The site's locale files already translate them, which is why dot-locale reads that layout. **The keys were checked against the site's `locales/en/party.json` and source, not guessed** ([history](history.md#the-first-refusal-keys-were-invented)). The few management refusals the site throws as bare tRPC codes (kick, roles, the ready round) have hub-only keys under `party.manage.deny.*` and neighbours, and the hub's class note says so.

## The local hub is the site's rules in the site's order

`DotPartyLocalHub` is `CanJoinParty` in order: ended, banned, alreadyIn, **the host always gets back in (even to a full party)**, full, type, then the after-start lock for walk-ins only. The order matters because the reason a person is given should be the most specific true one: telling a stranger that an invite-only party "has already started" discloses that it exists. The ready round is the site's too: all ready starts it; a threshold arms a countdown **once** and disarms below it, so re-arming restarts the count.

`DotPartyReservePolicy` is `ServerReservationOffer`, `ReserveWindowOpen` and `ReserveWindowCloses`, including the wrapped window (22:00 → 02:00) and clamping rather than refusing a booking that would run past it. These are copies on purpose, for the reason dot-stats' merge rule is: a LAN server with no website still has to answer them, and two implementations that disagree about a window turn a party away from a server the site said was theirs. **A change to any of these rules on the site needs the same change here**, and the suite section that covers it.

## The client polls because the site pushes nothing

There is no party socket on the site; its own pages poll. `DotPartyClient` polls at `poll_sec` 22.5 s in a lobby and `ready_poll_sec` 1.5 s in a ready round, and heartbeats every 45 s against the site's 150 s staleness. `DotPartyConfig.validate()` refuses a heartbeat at or past 150, because every member would be dropped from their own party.

## Following is once per round, reset by the lobby

`connect_requested` fires once per `party|server|url`. Going back to LOBBY or SEARCHING clears it, so a second round on the **same** server is followed again; without that, a party that played, went back to the lobby and started again on the same server would leave everyone in the menu.

The party snapshot does not carry the connect address (the site builds it only for a JOINED member in the ready view), so `refresh()` asks `GET party/{id}/ready` whenever the snapshot is READY with no address. The local hub's snapshot does carry it, which is why the suite could not see this ([contract](backbone-contract.md#why-the-connect-url-matters)).

## A kick is told as a kick

When the player is in no party, `mine()` answers null, which says nothing about why. `refresh()` then fetches the party it was in once and reads its own row: KICKED, BANNED or LEFT. The contract requires `GET party/{id}` to include the caller's own row even when no longer joined, for this.

## A booking admits through the ban seam, chained, and hands it back

`DotPartyReservations` registers as `dot_ban_source` after capturing whatever was there (dot-moderation, dot-server-security's feeds), asks it too, and **re-registers it on exit** so removing parties at runtime does not remove the bans. The address-only admission pass is always admitted: a booking is about people. Members are recognised by `backbone:<userId>`, never by name; matching display names would let a stranger in by calling themselves the host.

**An outage keeps the booking.** `sync()` failing leaves the booking in force; the alternative opens a private server whenever the website hiccups.

## The state report is absolute and never carries a uid

`party/state` gets the whole player list every time (`state_report_sec`, 15 s): a lost delta is wrong forever, a lost snapshot is corrected by the next. The session uid is stripped from every row: the site matches by name and `steamId`, and sending `backbone:<id>` back tagged with a server would be a correlation the platform does not otherwise make.

## Deliberately not here

- **The site's routes.** website-city is its own repository with its own migrations and tests.
- **A party UI.** dot-ui draws; this emits.
- **Party voice or party chat.** dot-voice and dot-chat own routing. dot-chat's grouped channel (`DotChatChannel.group(&"party", "Party")` with `DotChatRouter.group_fn` answering `DotPartyServer.party_of(uid)`) is party chat; dot-server-deploy's `host/tmc_party.gd` wires it into each game's router.
- **The server finder.** The site's `PartySearch` loosens a party's criteria one step per pass against its `Server` table; dot-matchmaking is the player-queue half.

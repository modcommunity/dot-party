# dot-party

Parties that play together, from both ends of the TMC backbone's party system: the player's client and the game server.

**The distributable is `addons/dot_party/`.** It requires [dot-core](../dot-core), a separate repository, and nothing else. dot-auth's clients and dot-server's admission seam are reached by duck typing and never named.

```bash
ln -s ../../dot-core/addons/dot_core addons/dot_core
```

## Why this exists, and what already existed

website-city has a complete party system — `Party`, `PartyMember`, invites, a ready round, a server finder, reservations with owner terms — and until this addon **no dot-* addon spoke a word of it**. game-arena's `arena_party.gd` and its siblings are peer-to-peer sessions over dot-peer-to-peer, which is a different thing that happens to share the word.

Two halves, and they are in very different states on the site:

| | Site routes | Here |
| --- | --- | --- |
| The **game server** tracking a party | Exist: `/api/integration/v1/party/{id,state,session,match,create,end}` | `DotPartyServer` |
| The **game server** learning it is booked | **Added** on website-city branch `feat/game-backbone`, not yet deployed — the site's own audit had said a private booking is never sent to the server | `DotPartyReservations`, via `party/reservation` |
| The **player** managing their party | **Added** on website-city branch `feat/game-backbone`, not yet deployed — before, only tRPC behind the website's session cookie, which a game client does not hold | `DotPartyBackendApp`, via `/api/app/v1/party/*` |

The added routes are listed in [docs/backbone-contract.md](docs/backbone-contract.md), each a wrapper over a function the site already had, with that function's own input names. Both halves have been driven from Godot against a live dev server of that branch, 25 checks, none failing.

## The pieces

| | |
| --- | --- |
| `DotParty`, `DotPartyMember` | The site's party and member, field for field. The id is a decimal **string**, because JSON rounds past 2^53 and the rounded id names somebody else's party. |
| `DotPartyReady` | The site's `PartyReadyView`. |
| `DotPartyReservation`, `DotPartyReservePolicy` | A booking, and an owner's terms — `ServerReservationOffer` ported line for line. |
| `DotPartyBackend` | The interface. Every method may await; call them all with `await`. |
| `DotPartyBackendApp` | The site as the player, through dot-auth's `post_app`/`get_app` (preferred) or a token and a `DotHttp`. |
| `DotPartyLocalHub`, `DotPartyBackendLocal` | The site's rules in-process. LAN, offline, suites. One hub, one backend per person. |
| `DotPartyClient` | The player's node: polls, heartbeats, diffs snapshots into signals, follows the party to its server. |
| `DotPartyServer` | The server's node: claims, rosters, the absolute state report, sessions, rounds. |
| `DotPartyReservations` | The server's node that enforces a booking, through `dot_ban_source`, chained. |

## Decisions

### Refusals are the site's keys, and only the site's keys where the site has them

`DotError.detail` carries `party.join.deny.full`, `party.reserve.deny.window` and so on, from every backend. The site's locale files already translate them into nine languages, which is the whole reason [dot-locale](../dot-locale) reads that layout. **The keys were checked against the site's locale files and source, not guessed** — see "What building it found". The few management refusals the site throws as bare tRPC codes (kick, roles, the ready round) have hub-only keys under `party.manage.deny.*` and neighbours, and the hub's class note says so.

### `DotPartyLocalHub` is `CanJoinParty` in the site's order

Ended, banned, alreadyIn, **the host always gets back in (even to a full party)**, full, type, then the after-start lock for walk-ins only. The order is the site's because "the reason a person is given should be the most specific true one" — telling a stranger that an invite-only party "has already started" discloses that it exists. The ready round is the site's too: all ready starts it; a threshold arms a countdown **once** and disarms below it, so re-arming restarts the count rather than resuming it.

### The client polls because the site pushes nothing

There is no socket for parties on the site; its own pages poll. `DotPartyClient` polls at 22.5 s in a lobby and 1.5 s in a ready round, and heartbeats every 45 s against the site's 150 s staleness — `DotPartyConfig.validate()` refuses a heartbeat at or past 150, because every member would be dropped from their own party.

### Following is once per round, and a round is reset by the lobby

`connect_requested` fires once per `party|server|url`. Going back to LOBBY or SEARCHING clears it, so a second round on the **same** server is followed again. Without that, a party that played, went back to the lobby and started again on the same server would leave everyone sitting in the menu.

### A kick is told as a kick

When the player is no longer in any party, `mine()` answers null, which says nothing about why. `refresh()` then fetches the party it was in once and reads its own row — KICKED, BANNED or LEFT. The contract requires `GET party/{id}` to include the caller's own row even when they are no longer joined, for this.

### A booking admits through the ban seam, chained, and hands it back

`DotPartyReservations` registers as `dot_ban_source` after capturing whatever was there (dot-moderation, dot-server-security's feeds), asks it too, and **re-registers it on exit** so removing parties at runtime does not remove the bans. The address-only admission pass is always admitted — a booking is about people. Members are recognised by `backbone:<userId>`, never by name.

### An outage keeps the booking

`sync()` failing leaves the booking in force. The alternative opens a private server whenever the website hiccups.

### The state report is absolute and never carries a uid

`party/state` gets the whole player list every time (the site's rule: a lost delta is wrong forever, a lost snapshot is corrected by the next). The session uid is stripped from every row: the site matches by name and steam id, and shipping `backbone:<id>` back to it tagged with a server would be a correlation the platform does not otherwise make.

## What building it found

**`is_connected()` on `DotPartyMember` shadowed `Object.is_connected`.** Every script in the addon failed to parse, each blaming a different line, exactly as `docs/gdscript-hazards.md` describes. It is `has_connected()`.

**The refusal keys first written here were invented, and wrong.** `party.join.deny.private`, `.password` and `.friends` do not exist; the site says `needInvite`, `wrongPassword` and `notFriend`. Reading `locales/en/party.json` and `src/lib/party/access.ts` also turned up two rules the first version did not have: the host always gets back into their own party, full or not, and joining a party you are already in is `alreadyIn` rather than a quiet success. A game written against the first version would have shown English-only fallback text for every refusal and let a host be locked out of a full party offline that the site would have let in.

**dot-auth's `_app_refusal` read a shape the site never sends.** It looked for `{ok: false, error: {code, message}}`; `contract.ts`'s `ApiErrorSchema` and `apiError()` send `{ok: false, code, message, retryAfter?}` flat. So every refusal through `DotAuthClient.post_app`/`get_app` lost the site's code and message and came back as "The request was refused." — including dot-stats' app-token submissions. Fixed in dot-auth (flat first, nested still accepted) with a suite section there.

**`mine()` returning null cost the kick reason** — see Decisions.

**The suite's own booking was refused, correctly.** A third local booking was made while nine people sat on an empty-only server; `book()` said `populated`. The check that failed was the test's assumption, and it is now a check of the refusal.

## Things deliberately not here

- **The site's routes.** Specified, not written; website-city is its own repository with its own migrations and tests.
- **A party UI.** dot-ui draws; this emits.
- **Party voice or party chat.** dot-voice and dot-chat own routing. dot-chat's `MEMBERS` scope could not do party chat — `membership_fn(peer, channel)` does not know the sender — and now has a grouped channel for it: `DotChatChannel.group(&"party", "Party")` with `DotChatRouter.group_fn` answering `DotPartyServer.party_of(uid)`. dot-server-deploy's `TmcParty` wires exactly that into every game's router.
- **The server finder.** The site's `PartySearch` loosens a party's criteria one step per pass against the `Server` table; that is the site's job and dot-matchmaking is the player-queue half.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
timeout 120 godot --headless --path . res://examples/party_selftest.tscn
```

9 sections, 132 checks, no network. **Section 7 is the one to keep**: a private booking admits only its party and still honours the ban list behind it, a public one holds seats while the party loads, and a backbone outage leaves the booking in force.

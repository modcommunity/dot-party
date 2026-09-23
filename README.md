This is the **party** asset for TMC's **Dot** collection. It adds parties — people who play together — to a game, fully integrated with the TMC website's party system: a party is tracked from the lobby to the server, its members join that server together, and a server can be booked for a party for an evening and actually keep it for them.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

## The website owns the party; the game keeps a copy

Parties live on the TMC website. That is where they are created, joined, invited to and ended, and where their history is kept. Every game client and every game server holds a snapshot that is only as fresh as its last poll, so nothing in this asset decides anything by editing a snapshot. Every change is asked of a `DotPartyBackend`, and the answer is a new snapshot.

There are two backends, and a game holds one without knowing which:

| | |
| --- | --- |
| `DotPartyBackendApp` | The website, as the signed-in player. |
| `DotPartyBackendLocal` | The website's rules, run in-process, for a LAN, an offline build and the test suite. |

Refusals carry the website's own reason key (`party.join.deny.full`, `party.reserve.deny.window`) in `DotError.detail`, from either backend. The website already translates those keys into nine languages, and [dot-locale](https://github.com/modcommunity/dot-locale) can show them in the player's.

## Joining a server together

A party's **ready round** is how it moves: the host picks a server, everybody is told where to connect, and the round starts when everybody is ready — or, if the party set a threshold, when that share is ready and a countdown runs out.

`DotPartyClient` polls the party (fast during a ready round, relaxed otherwise), heartbeats so the website does not drop the player, and turns each new snapshot into events: somebody joined, somebody was kicked, the stage changed. When a ready round opens, it asks the game to connect once, reports that the player arrived, and does it again the next time the party moves.

```gdscript
var party := DotPartyClient.new()
var app := DotPartyBackendApp.new()
app.client = auth          # dot-auth's DotAuthClient: it holds the token and refreshes it
party.backend = app
party.user_id = auth.identity().uid.trim_prefix("backbone:")
party.connect_fn = func(url: String, _info: Dictionary) -> DotResult:
    return await game.connect_to(url)
add_child(party)

party.member_joined.connect(func(m): hud.toast("%s joined" % m.display_name))
party.left_party.connect(func(_id, why): if why == "kicked": hud.toast("You were removed from the party"))
```

## A booked server keeps its promise

A party can book a server for up to a few hours if the server's owner allows it. Before this asset, a **private** booking was only a promise on the website: nothing told the game server, so anybody with the address got in.

`DotPartyReservations` is the server's half. It learns the booking (from the website, from a local hub, or from the owner at the console) and answers the admission question dot-server already asks on every join:

- A **private** booking admits the party and nobody else, apart from people the owner lets through (usually admins).
- A **public** booking leaves the server open, but **holds a seat for every member who has not arrived yet**, for the first few minutes. Otherwise eight friends who booked a server lose it to whoever connects while they are loading the map.

It **chains** onto whatever ban list is already installed rather than replacing it, so a banned player is still banned on a booked server. If the website cannot be reached, the booking stays in force: an outage must not open a private server.

The owner's booking terms are `DotPartyReservePolicy`, which uses the same rules as the website: booking hours in UTC (including a window that crosses midnight), a maximum length that is clamped rather than refused, only-when-empty, a cooldown, and public or private shapes.

## Tracking a party on a game server

`DotPartyServer` tells the website who from which party is on the server, so their play time, rounds and scores are recorded. It uses integration routes the website already has: a full roster report every fifteen seconds, exact join and leave events, and round results with places.

A joining client names its party. The server fetches that party's roster and checks the person is on it before tracking anything, so claiming a party you are not in does nothing.

`groups(uids)` returns connected players grouped by party, for a team balancer that should keep parties together.

## What the website still needs

The server half uses routes the website already serves. **The player half does not exist on the website yet.** Parties are managed on the website through its own session login, which a game client does not have, and the app API a game signs in to has no party routes. The same is true of telling a game server that it has been booked.

[docs/backbone-contract.md](docs/backbone-contract.md) specifies the missing routes. Each one wraps a function the website already has, and uses the input names the website already uses. Until they exist, the app backend fails each call with a message that says so, and `DotPartyBackendLocal` gives a game the same behaviour offline.

## Installing

Copy `addons/dot_party/` and [`dot-core`](https://github.com/modcommunity/dot-core)'s `addons/dot_core/` into your project and enable it in **Project → Project Settings → Plugins**.

## Dependencies

[dot-core](https://github.com/modcommunity/dot-core). Nothing else. dot-auth's backbone client and dot-server's admission check are reached by duck typing and never named.

## Licence

MIT. See [LICENSE](LICENSE).

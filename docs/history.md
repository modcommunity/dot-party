# History

What building dot-party found. The lessons that still apply are in [design.md](design.md) and [backbone-contract.md](backbone-contract.md).

## `is_connected()` shadowed `Object.is_connected`

A method of that name on `DotPartyMember` made every script in the addon fail to parse, each blaming a different line, as [gdscript-hazards.md](../../../docs/gdscript-hazards.md) describes. It is `has_connected()`.

## The first refusal keys were invented

`party.join.deny.private`, `.password` and `.friends` do not exist; the site says `needInvite`, `wrongPassword` and `notFriend`. Reading `locales/en/party.json` and `src/lib/party/access.ts` also turned up two rules the first version lacked: the host always gets back into their own party, full or not, and joining a party you are already in is `alreadyIn`, not a quiet success. A game on the first version would have shown English-only fallback text for every refusal and locked a host out of their own full party offline.

## dot-auth read a refusal shape the site never sends

dot-auth's `_app_refusal` looked for `{ok: false, error: {code, message}}`; the site's `ApiErrorSchema` sends `{ok: false, code, message, retryAfter?}` flat. Every refusal through `DotAuthClient.post_app` / `get_app` lost the site's code and message, including dot-stats' app-token submissions. Fixed in dot-auth (flat first, nested still accepted), with a suite section there.

## `mine()` returning null cost the kick reason

See [design.md](design.md#a-kick-is-told-as-a-kick).

## The ready round never followed against the real site

The local hub's snapshot carried the connect address and the site's does not, so the suite passed and a real client never connected. Both halves were then driven from Godot against a live dev server of the site (create, join, the alreadyIn refusal, the roster, the ready view, a kick reported as a kick, and a private booking that admits the host and refuses a stranger). See [the contract](backbone-contract.md#why-the-connect-url-matters).

## The suite's own booking was refused, correctly

A third local booking was made while nine people sat on an empty-only server, and `book()` said `populated`. The failing check was the test's assumption; it is now a check of the refusal.

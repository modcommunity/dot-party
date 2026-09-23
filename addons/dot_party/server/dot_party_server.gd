class_name DotPartyServer
extends Node

## The game server's side of the backbone's party tracking: who from which party is here,
## reported so the site records their play, their rounds and their scores.
##
## [b]Speaks routes the site already serves.[/b] Unlike the player's half, everything here
## exists in website-city today: [code]GET party/{id}[/code], [code]party/state[/code],
## [code]party/session[/code], [code]party/match[/code], [code]party/create[/code] and
## [code]party/end[/code] under [code]/api/integration/v1[/code], with the scopes
## [code]PARTY_READ[/code], [code]PARTY_STATE[/code], [code]PARTY_SESSION[/code],
## [code]PARTY_STATS[/code] and [code]PARTY_WRITE[/code]. See the site's
## [code]docs/api/integration-api.md[/code].
##
## [b]The state report is absolute.[/b] Every [member DotPartyConfig.state_report_sec] the
## whole player list goes to every party being tracked, not the changes since last time —
## the site's rule, because a lost delta is a wrong roster forever and a lost snapshot is
## corrected by the next one. [method player_joined] and [method player_left] add exact
## timings on top; they complement the snapshot and never replace it.
##
## [b]A client says which party it is in; the server believes the roster.[/b] The site has
## no "which party is this person in" route for a server, so a joining client names its
## party — [method claim] — and the server fetches that party's roster and checks the
## person is actually on it before tracking anything. A client that names a party it is
## not in has changed nothing.
##
## [b]dot-auth is not named.[/b] [member client] is any object with
## [code]post_integration(path, body)[/code] and [code]get_integration(path, query)[/code];
## it stamps [code]ts[/code] and the nonce and holds the credential.

const CHANNEL := "party.server"
const SERVICE := &"dot_party_server"

signal party_tracked(party: DotParty)
signal party_untracked(party_id: String)
signal report_failed(what: String, error: DotError)

@export var config: DotPartyConfig = null

var client: Object = null

## [code]func() -> Array[/code] of the players on the server now, each
## [code]{name, uid, score?, kills?, deaths?, assist?, seconds?, steamId?}[/code]. [code]uid[/code]
## is the session's, and never leaves the server; the site matches by name.
var players_fn: Callable = Callable()

## party id -> DotParty
var parties: Dictionary = {}

var _since_state: float = 0.0
var _since_roster: float = 0.0
var reports: int = 0
var failures: int = 0


func _ready() -> void:
	if config == null:
		config = DotPartyConfig.new()
	if not Engine.is_editor_hint():
		DotRegistry.register(SERVICE, self)


func _exit_tree() -> void:
	DotRegistry.unregister_instance(SERVICE, self)


func _process(delta: float) -> void:
	if parties.is_empty():
		return
	_since_state += delta
	_since_roster += delta
	if _since_state >= config.state_report_sec:
		_since_state = 0.0
		report_state()
	if _since_roster >= config.roster_refresh_sec:
		_since_roster = 0.0
		for id in parties.keys():
			refresh(str(id))


# --- Which parties are here --------------------------------------------------

## A connected player says they are in [param party_id]. Tracks the party if its roster
## agrees; refuses, and tracks nothing, if it does not.
func claim(uid: String, party_id: String) -> DotResult:
	if not DotParty.is_id(party_id):
		return DotResult.fail(DotError.CODE_INVALID, "That is not a party id.", party_id)
	var p: DotParty = parties.get(party_id)
	if p == null or not p.server_uids().has(uid):
		var fetched := await refresh(party_id)
		if not fetched.ok:
			return fetched
		p = fetched.value
	if not p.server_uids().has(uid):
		if p.size() == 0 or not _any_here(p):
			untrack(party_id)
		return DotResult.fail(DotError.CODE_FORBIDDEN, "You are not in that party.", party_id)
	return DotResult.success(p)


## Starts tracking [param p] as it is, with no fetch. For a party a booking brought.
func track(p: DotParty) -> void:
	var fresh := not parties.has(p.id)
	parties[p.id] = p
	if fresh:
		DotLog.info(CHANNEL, "tracking a party", {"party": p.id, "members": p.size()})
		party_tracked.emit(p)


func untrack(party_id: String) -> void:
	if parties.erase(party_id):
		party_untracked.emit(party_id)


## Re-reads one party's roster. An ended party is untracked.
func refresh(party_id: String) -> DotResult:
	var res := await _get_json("party/%s" % party_id)
	if not res.ok:
		return res
	var parsed := DotParty.from_dict(res.value as Dictionary)
	if not parsed.ok:
		return parsed
	var p: DotParty = parsed.value
	if not p.is_live():
		untrack(party_id)
		return DotResult.fail(DotError.CODE_STATE, "That party has ended.", party_id)
	track(p)
	return DotResult.success(p)


## The party [param uid] is in among those tracked, or "".
func party_of(uid: String) -> String:
	for id in parties:
		if (parties[id] as DotParty).server_uids().has(uid):
			return str(id)
	return ""


func same_party(uid_a: String, uid_b: String) -> bool:
	var a := party_of(uid_a)
	return a != "" and a == party_of(uid_b)


## [param uids] grouped so that everybody in one party is in one group, and everybody in
## none is a group of one. What a team balancer is handed so it moves parties whole —
## the same promise dot-matchmaking's balancer keeps.
func groups(uids: PackedStringArray) -> Array:
	var by_party := {}
	var out := []
	for uid in uids:
		var pid := party_of(uid)
		if pid == "":
			out.append(PackedStringArray([uid]))
			continue
		if not by_party.has(pid):
			by_party[pid] = out.size()
			out.append(PackedStringArray())
		var g: PackedStringArray = out[int(by_party[pid])]
		g.append(uid)
		out[int(by_party[pid])] = g
	return out


# --- Reporting -----------------------------------------------------------------

## The whole picture, to every tracked party. [code]party/state[/code].
func report_state(map_name: String = "", game_mode: String = "") -> DotResult:
	var players := _players()
	var last := DotResult.success(0)
	for id in parties.keys():
		var body := {"partyId": str(id), "players": players}
		if map_name != "":
			body["mapName"] = map_name
		if game_mode != "":
			body["gameMode"] = game_mode
		var res := await _post("party/state", body)
		if not res.ok:
			last = res
	return last


## An exact join. [code]party/session[/code] to the party the player is in — or, for a
## player with no backbone identity, to every tracked party, since the site matches by
## name and we cannot.
func player_joined(player: Dictionary) -> void:
	await _session("join", player)


func player_left(player: Dictionary) -> void:
	await _session("leave", player)


## A round began. [code]party/match[/code] with [code]event: start[/code].
func match_started(map_name: String = "", game_mode: String = "") -> DotResult:
	return await _match("start", map_name, game_mode, _players())


## A round finished. [param results] is the player list with a [code]place[/code] on each.
func match_ended(results: Array, map_name: String = "", game_mode: String = "") -> DotResult:
	return await _match("end", map_name, game_mode, results)


## Creates a party as this server — "everybody here, as a party" — and tracks it.
## [code]type[/code] is PUBLIC or FRIENDS only: a machine-made password party would have a
## password only the machine knows.
func create_party(party_name: String, max_users: int = 8, type: String = "PUBLIC") -> DotResult:
	if type != "PUBLIC" and type != "FRIENDS":
		return DotResult.fail(DotError.CODE_INVALID, "A server may only create PUBLIC or FRIENDS parties.", type)
	var res := await _post("party/create", {"name": party_name, "maxUsers": clampi(max_users, 2, 256), "type": type})
	if not res.ok:
		return res
	var id := str((res.value as Dictionary).get("partyId", ""))
	var fetched := await refresh(id)
	return fetched if fetched.ok else DotResult.success({"partyId": id})


## Ends a party this server created. Recorded by the site as ended by the SERVER, not the host.
func end_party(party_id: String) -> DotResult:
	var res := await _post("party/end", {"partyId": party_id})
	if res.ok:
		untrack(party_id)
	return res


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("party tracking: %d parties, %d reports, %d failures" % [parties.size(), reports, failures])
	for id in parties:
		out.append_array((parties[id] as DotParty).describe_lines())
	return out


# --- Plumbing ------------------------------------------------------------------

func _session(event: String, player: Dictionary) -> void:
	var row := _wire_player(player)
	var targets := PackedStringArray()
	var uid := str(player.get("uid", ""))
	var pid := party_of(uid)
	if pid != "":
		targets.append(pid)
	elif not uid.begins_with("backbone:"):
		for id in parties:
			targets.append(str(id))
	for id in targets:
		await _post("party/session", {"partyId": id, "event": event, "player": row})


func _match(event: String, map_name: String, game_mode: String, rows: Array) -> DotResult:
	var players := []
	for r in rows:
		var d: Dictionary = r
		var w := _wire_player(d)
		if d.has("place"):
			w["place"] = int(d["place"])
		players.append(w)
	var last := DotResult.success(null)
	for id in parties.keys():
		var body := {"partyId": str(id), "event": event, "players": players}
		if map_name != "":
			body["mapName"] = map_name
		if game_mode != "":
			body["gameMode"] = game_mode
		var res := await _post("party/match", body)
		if not res.ok:
			last = res
	return last


func _players() -> Array:
	var out := []
	if not players_fn.is_valid():
		return out
	var raw: Variant = players_fn.call()
	if not (raw is Array):
		return out
	for p in raw:
		if p is Dictionary:
			out.append(_wire_player(p as Dictionary))
		if out.size() >= 256:
			# The site takes 256 per report. A bigger server reports its first 256 rather
			# than having every report refused.
			break
	return out


## The site's IngestPlayer. The session uid is deliberately NOT sent: the backbone matches
## by name and steam id, and a server that shipped uids would be handing the site's own
## account ids back to it tagged with which server they were seen on.
static func _wire_player(p: Dictionary) -> Dictionary:
	var out := {"name": str(p.get("name", "")).substr(0, 128)}
	if str(p.get("steamId", "")) != "":
		out["steamId"] = str(p["steamId"])
	for k in ["score", "kills", "deaths", "assist", "seconds"]:
		if p.has(k):
			out[k] = int(p[k])
	return out


func _any_here(p: DotParty) -> bool:
	if not players_fn.is_valid():
		return false
	var raw: Variant = players_fn.call()
	if not (raw is Array):
		return false
	var here := p.server_uids()
	for row in raw:
		if row is Dictionary and here.has(str((row as Dictionary).get("uid", ""))):
			return true
	return false


func _post(path: String, body: Dictionary) -> DotResult:
	if client == null or not client.has_method("post_integration"):
		return DotResult.fail(DotError.CODE_STATE, "no backbone client")
	var res: DotResult = await client.call("post_integration", path, body)
	if res.ok:
		reports += 1
	else:
		failures += 1
		report_failed.emit(path, res.error)
		if res.error != null and res.error.http_status == 403:
			return res.wrap("the integration credential needs the party scopes for %s" % path)
	return res


func _get_json(path: String) -> DotResult:
	if client == null or not client.has_method("get_integration"):
		return DotResult.fail(DotError.CODE_STATE, "no backbone client")
	return await client.call("get_integration", path, {})

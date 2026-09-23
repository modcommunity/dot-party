class_name DotPartyClient
extends Node

## The player's party, kept current, and the thing that takes them to where it is playing.
##
## [b]Polled, because the backbone pushes nothing.[/b] website-city has no socket for
## parties; its own pages poll, at about half the heartbeat interval in a lobby and every
## second and a half on the ready screen. This does the same, faster when it matters: a
## party in its ready round is a party whose members are about to be told where to go, and
## a client that learns it twenty seconds late is the one person the round waits for.
##
## [b]Heartbeats are not optional.[/b] The site drops a member it has not heard from in 150
## seconds. A game that polled but did not heartbeat would watch its own player be removed
## from the party they are sitting in.
##
## [b]Every snapshot is diffed into events.[/b] A game wants "Sam joined" and "the round
## is starting", not a fresh roster to compare by hand — and when every game compares by
## hand, one of them compares StringNames and gets a different order on each peer. So
## [method apply_snapshot] is the one place a party changing becomes signals, and the
## suite drives it directly.
##
## [b]Following is joining together.[/b] When the party's ready round opens with somewhere
## to connect, [signal connect_requested] fires once for that round. With
## [member follow] on and a [member connect_fn], the client connects by itself and then
## tells the backbone it arrived, which is what lets the round start the moment the last
## person is in rather than when somebody notices. A leader moving the party to another
## server is a new round, and the same thing happens again.

const CHANNEL := "party.client"

signal party_changed(party: DotParty)
signal joined_party(party: DotParty)
## [param reason]: "left", "kicked", "banned", "ended".
signal left_party(party_id: String, reason: String)
signal member_joined(member: DotPartyMember)
## [param reason]: "left", "kicked", "banned", "stale".
signal member_left(member: DotPartyMember, reason: String)
signal role_changed(member: DotPartyMember, old_role: DotPartyMember.Role)
signal stage_changed(old_stage: DotParty.Stage, new_stage: DotParty.Stage)
signal ready_changed(member: DotPartyMember)
## The party wants everybody on this server now. Once per ready round.
signal connect_requested(url: String, info: Dictionary)
## A request to the backbone failed. The snapshot is unchanged.
signal request_failed(what: String, error: DotError)

@export var config: DotPartyConfig = null

## Connect and report arrival automatically when the ready round opens.
@export var follow: bool = true

var backend: DotPartyBackend = null

## This player's backbone user id, so the client can tell "I was kicked" from "Sam was".
var user_id: String = ""

## [code]func(url: String, info: Dictionary) -> DotResult[/code], awaited. The game's
## "connect to this server". Without one, [signal connect_requested] is all that happens.
var connect_fn: Callable = Callable()

## The current snapshot, or null when not in a party.
var party: DotParty = null

## The round already followed, as "partyId|serverId|url", so a poll during a round does not
## connect a second time. Cleared when the party goes back to its lobby.
var _followed_round: String = ""
var _since_poll: float = 0.0
var _since_beat: float = 0.0
var _busy: bool = false


func _ready() -> void:
	if config == null:
		config = DotPartyConfig.new()


func _process(delta: float) -> void:
	if backend == null or Engine.is_editor_hint():
		return
	_since_poll += delta
	_since_beat += delta
	if party != null and _since_beat >= config.heartbeat_sec:
		_since_beat = 0.0
		_beat()
	if _since_poll >= poll_interval():
		_since_poll = 0.0
		refresh()


## How often to poll now: fast in a ready round, relaxed otherwise.
func poll_interval() -> float:
	if party != null and party.stage == DotParty.Stage.READY:
		return config.ready_poll_sec
	return config.poll_sec


## Fetches the current party and applies it. Safe to call at any time; overlapping calls
## are dropped rather than queued, because the second answer would only repeat the first.
func refresh() -> DotResult:
	if backend == null or _busy:
		return DotResult.success(party)
	_busy = true
	var res: DotResult = await backend.mine()
	_busy = false
	if not res.ok:
		request_failed.emit("refresh", res.error)
		return res
	var next: DotParty = res.value
	if next == null and party != null:
		# "In no party" does not say why. The party we were in does — our own row in it
		# reads KICKED or BANNED — and a player told they "left" a party they were thrown
		# out of goes looking for a bug.
		_busy = true
		var old: DotResult = await backend.fetch(party.id)
		_busy = false
		if old.ok and old.value != null:
			next = old.value
	apply_snapshot(next)
	return DotResult.success(party)


## Turns a new snapshot into signals. [param next] null means "in no party".
##
## A snapshot of a party this player is not a live member of — ended, or one they were
## kicked from between two polls — is the same as null, with the reason read off it.
func apply_snapshot(next: DotParty) -> void:
	var in_next := next != null and next.is_live() and (user_id == "" or next.member(user_id) != null)
	var prev := party

	if prev != null and (not in_next or next.id != prev.id):
		party = null
		_followed_round = ""
		left_party.emit(prev.id, _departure_reason(prev, next))
		prev = null
		if not in_next:
			party_changed.emit(null)
			return

	if not in_next:
		return

	party = next
	if prev == null:
		joined_party.emit(next)
	else:
		_diff_members(prev, next)
		if prev.stage != next.stage:
			stage_changed.emit(prev.stage, next.stage)
			# Back in the lobby: the next ready round is a new one, even on the same server.
			if next.stage == DotParty.Stage.LOBBY or next.stage == DotParty.Stage.SEARCHING:
				_followed_round = ""

	party_changed.emit(next)
	_maybe_follow(next)


## Why this player is no longer in [param prev], from what [param next] says about them.
func _departure_reason(prev: DotParty, next: DotParty) -> String:
	if next == null or next.id != prev.id:
		return "left"
	if not next.is_live():
		return "ended"
	for m in next.roster:
		if m.user_id != user_id:
			continue
		if m.state == DotPartyMember.State.KICKED:
			return "kicked"
		if m.state == DotPartyMember.State.BANNED:
			return "banned"
	return "left"


func _diff_members(prev: DotParty, next: DotParty) -> void:
	# Keyed by user id and compared as Strings. Iteration order is the roster's, which is
	# the backbone's join order, so two clients announce the same people in the same order.
	var before := {}
	for m in prev.members():
		before[m.user_id] = m
	var after := {}
	for m in next.members():
		after[m.user_id] = m

	for m in next.members():
		if not before.has(m.user_id):
			member_joined.emit(m)
			continue
		var old: DotPartyMember = before[m.user_id]
		if old.role != m.role:
			role_changed.emit(m, old.role)
		if old.is_ready() != m.is_ready():
			ready_changed.emit(m)

	for m in prev.members():
		if after.has(m.user_id):
			continue
		var reason := "left"
		for row in next.roster:
			if row.user_id == m.user_id:
				match row.state:
					DotPartyMember.State.KICKED:
						reason = "kicked"
					DotPartyMember.State.BANNED:
						reason = "banned"
		member_left.emit(m, reason)


func _maybe_follow(p: DotParty) -> void:
	if p.stage != DotParty.Stage.READY or p.connect_info.is_empty():
		return
	var url := str(p.connect_info.get("url", ""))
	if url == "":
		return
	var round_key := "%s|%s|%s" % [p.id, str(p.connect_info.get("serverId", "")), url]
	if round_key == _followed_round:
		return
	_followed_round = round_key
	connect_requested.emit(url, p.connect_info)
	if follow and connect_fn.is_valid():
		_follow(p.id, url, p.connect_info)


func _follow(party_id: String, url: String, info: Dictionary) -> void:
	var res: Variant = await connect_fn.call(url, info)
	if res is DotResult and not (res as DotResult).ok:
		DotLog.warn(CHANNEL, "could not follow the party", {"url": url, "detail": str((res as DotResult).error)})
		# Let the next poll try again rather than leaving the player behind for good.
		_followed_round = ""
		return
	await report_connected()


# --- Actions -----------------------------------------------------------------
#
# Each asks the backend and then refreshes, so the snapshot and its signals come from what
# the backbone now says rather than from what this client assumed it would say.

func create(options: Dictionary) -> DotResult:
	return await _act("create", backend.create.bind(options))


func join(party_id: String, password: String = "", token: String = "") -> DotResult:
	if not DotParty.is_id(party_id):
		return DotResult.fail(DotError.CODE_INVALID, "That is not a party id.", party_id)
	return await _act("join", backend.join.bind(party_id, password, token))


func leave() -> DotResult:
	if party == null:
		return DotResult.success(null)
	return await _act("leave", backend.leave.bind(party.id))


func kick(target_user_id: String, ban: bool = false) -> DotResult:
	if party == null:
		return DotResult.fail(DotError.CODE_STATE, "You are not in a party.")
	return await _act("kick", backend.kick.bind(party.id, target_user_id, ban))


func invite(user_ids: PackedStringArray, message: String = "") -> DotResult:
	if party == null:
		return DotResult.fail(DotError.CODE_STATE, "You are not in a party.")
	return await _act("invite", backend.invite.bind(party.id, user_ids, message))


func start(server_id: int = 0) -> DotResult:
	if party == null:
		return DotResult.fail(DotError.CODE_STATE, "You are not in a party.")
	return await _act("start", backend.start.bind(party.id, server_id))


func set_ready(is_ready: bool = true) -> DotResult:
	if party == null:
		return DotResult.fail(DotError.CODE_STATE, "You are not in a party.")
	return await _act("set_ready", backend.set_ready.bind(party.id, is_ready))


func report_connected() -> DotResult:
	if party == null:
		return DotResult.fail(DotError.CODE_STATE, "You are not in a party.")
	return await _act("connected", backend.connected.bind(party.id))


func reserve(server_id: int, minutes: int, private: bool = false) -> DotResult:
	if party == null:
		return DotResult.fail(DotError.CODE_STATE, "You are not in a party.")
	return await _act("reserve", backend.reserve.bind(party.id, server_id, minutes, private))


func is_host() -> bool:
	return party != null and party.host_id == user_id


func can_manage() -> bool:
	return party != null and party.can_manage(user_id)


func describe_lines() -> PackedStringArray:
	if party == null:
		return PackedStringArray(["party: none (%s)" % (backend.describe() if backend != null else "no backend")])
	return party.describe_lines()


## [param fn] is a bound backend method rather than its result. Calling a coroutine and
## passing on what it returned would hand over a suspended call, and whether awaiting that
## later works is not something to find out against the one backend the suite does not use.
func _act(what: String, fn: Callable) -> DotResult:
	var res: Variant = await fn.call()
	if res is DotResult and not (res as DotResult).ok:
		request_failed.emit(what, (res as DotResult).error)
		return res
	await refresh()
	return res if res is DotResult else DotResult.success(res)


func _beat() -> void:
	var res: DotResult = await backend.heartbeat(party.id)
	if not res.ok:
		request_failed.emit("heartbeat", res.error)

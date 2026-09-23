class_name DotPartyLocalHub
extends RefCounted

## Parties with no website: the backbone's rules, run in-process.
##
## For a LAN, an offline build, a game that ships its own party screen without TMC, and
## the suite. Several [DotPartyBackendLocal]s share one hub, each acting as one person —
## the same shape as dot-peer-to-peer's loopback signaller, and for the same reason: the
## interesting bugs are between two people, so the test has to have two.
##
## [b]The rules are the site's, deliberately.[/b] A person is in at most one live party and
## joining another leaves the first; the host leaving does not end a party but the last
## member leaving does; a member not heard from in 150 seconds has left; a ready round
## starts when everybody is ready, or arms a countdown once the party's threshold share is
## ready and disarms it if that share drops. A game developed against this and deployed
## against the site must not discover a different party system on launch day.
##
## Where the site's rule depends on something a hub cannot know — a friends graph — it is
## a callable the game supplies: [member friends_fn].
##
## [b]Refusal keys.[/b] Joining and booking refuse with the site's own keys
## ([code]party.join.deny.*[/code], [code]party.reserve.deny.*[/code]), which its locale
## files already translate into nine languages. The site's management procedures refuse
## with tRPC codes rather than keys, so the few keys here for kicking, roles and the ready
## round ([code]party.manage.deny.role[/code] and its neighbours) are this hub's own.

const CHANNEL := "party.local"

## The site's constants.
const HEARTBEAT_SEC := 45
const MEMBER_STALE_SEC := 150
const INVITE_BATCH_MAX := 25
const PASSWORD_MIN := 4
const PASSWORD_MAX := 128

## Unix seconds. The suite replaces it.
var now_fn: Callable = func() -> int: return int(Time.get_unix_time_from_system())

## [code]func(a: String, b: String) -> bool[/code]: whether two users are friends, for
## FRIENDS parties. Without one, a FRIENDS party admits by invitation only.
var friends_fn: Callable = Callable()

## user id -> display name, for rosters.
var names: Dictionary = {}

## party id -> DotParty (the authority; everything handed out is a copy)
var _parties: Dictionary = {}
## party id -> {password_hash, auto_pct, auto_sec, join_after_start, ready_opened, deadline, bans: {}}
var _extra: Dictionary = {}
## user id -> last heartbeat, per party id: "pid|uid" -> Unix seconds
var _seen: Dictionary = {}
## invite id -> {id, partyId, inviterId, userId, status, message}
var _invites: Dictionary = {}
## server id -> {policy, humans, online, name, url}
var _servers: Dictionary = {}
var _reservations: Array[DotPartyReservation] = []
var _next_id: int = 4470
var _next_invite: int = 1
var _next_reservation: int = 1


func as_user(user_id: String, display_name: String = "") -> DotPartyBackendLocal:
	if display_name != "":
		names[user_id] = display_name
	return DotPartyBackendLocal.new(self, user_id)


func now() -> int:
	return int(now_fn.call())


# --- Servers -----------------------------------------------------------------

## Makes a server bookable in this hub. [param url] is what a ready round tells people
## to connect to.
func add_server(server_id: int, server_name: String, url: String,
		policy: DotPartyReservePolicy = null) -> void:
	_servers[server_id] = {
		"policy": policy if policy != null else DotPartyReservePolicy.new(),
		"humans": 0,
		"online": true,
		"name": server_name,
		"url": url,
	}


func set_population(server_id: int, humans: int) -> void:
	if _servers.has(server_id):
		(_servers[server_id] as Dictionary)["humans"] = humans


# --- Membership --------------------------------------------------------------

func create(user_id: String, options: Dictionary) -> DotResult:
	var max_users := int(options.get("maxUsers", 8))
	if max_users < DotParty.MIN_USERS or max_users > DotParty.MAX_USERS_CAP:
		return _deny(DotError.CODE_INVALID, "A party holds between 2 and 256 people.", "party.create.deny.size")
	var party_name := str(options.get("name", ""))
	if party_name.length() > DotParty.NAME_MAX:
		return _deny(DotError.CODE_INVALID, "That party name is too long.", "party.create.deny.name")
	var type := DotParty.parse_type(str(options.get("type", "PUBLIC")))
	var password := str(options.get("password", ""))
	if type == DotParty.Type.PUBLIC_PASSWORD and (password.length() < PASSWORD_MIN or password.length() > PASSWORD_MAX):
		return _deny(DotError.CODE_INVALID, "A password party needs a password of 4 to 128 characters.", "party.create.deny.password")

	# One live hosted party per person.
	for p in _parties.values():
		var live: DotParty = p
		if live.is_live() and live.host_id == user_id:
			return _deny(DotError.CODE_CONFLICT, "You are already hosting a party.", "party.create.deny.hosting")

	var left := _leave_every_party(user_id)

	var party := DotParty.new()
	party.id = str(_next_id)
	_next_id += 1
	party.name = party_name
	party.type = type
	party.max_users = max_users
	party.host_id = user_id
	party.start_time = now()
	party.server_id = int(options.get("serverId", 0)) if options.get("serverId") != null else 0
	var host := DotPartyMember.of(user_id, str(names.get(user_id, user_id)), DotPartyMember.Role.HOST)
	host.joined_at = now()
	party.roster.append(host)
	_parties[party.id] = party
	_extra[party.id] = {
		"password_hash": password.sha256_text() if password != "" else "",
		"auto_pct": int(options.get("readyAutoPct", 0)),
		"auto_sec": clampi(int(options.get("readyAutoSec", 30)), 5, 300),
		"join_after_start": bool(options.get("joinAfterStartPublic", false)),
		"join_after_start_friends": bool(options.get("joinAfterStartFriends", true)),
		"friends_can_join": bool(options.get("friendsCanJoin", true)),
		"ready_opened": 0,
		"deadline": 0,
		"bans": {},
	}
	_seen["%s|%s" % [party.id, user_id]] = now()
	DotLog.debug(CHANNEL, "party created", {"party": party.id, "host": user_id, "left": left})
	return DotResult.success(party.copy())


func join(user_id: String, party_id: String, password: String = "", token: String = "") -> DotResult:
	# The order is the site's CanJoinParty, because the reason a person is given should
	# be the most specific true one — and telling a stranger that an invite-only party
	# "has already started" would disclose that it exists and is running.
	var party := _live(party_id)
	if party == null:
		return _deny(DotError.CODE_STATE, "This party has ended.", "party.join.deny.ended")
	var extra: Dictionary = _extra[party_id]
	if (extra["bans"] as Dictionary).has(user_id):
		return _deny(DotError.CODE_FORBIDDEN, "You have been banned from this party.", "party.join.deny.banned")
	if party.member(user_id) != null:
		return _deny(DotError.CODE_CONFLICT, "You are already in this party.", "party.join.deny.alreadyIn")

	# The host always gets back into their own party, full or not: a host who dropped out
	# of a full party could otherwise never return to the party they are responsible for.
	var is_host := party.host_id == user_id
	var invited := false
	if not is_host:
		if party.is_full():
			return _deny(DotError.CODE_CONFLICT, "This party is full.", "party.join.deny.full")
		invited = _consume_invite(party_id, user_id, token)
		var friend := _is_friend(user_id, party)
		if not invited:
			match party.type:
				DotParty.Type.PRIVATE:
					return _deny(DotError.CODE_FORBIDDEN, "This party is invite only.", "party.join.deny.needInvite")
				DotParty.Type.PUBLIC_PASSWORD:
					# An invitee skips the password: somebody who knew it let them in.
					if password.sha256_text() != str(extra["password_hash"]):
						return _deny(DotError.CODE_FORBIDDEN, "That password was not correct.", "party.join.deny.wrongPassword")
				DotParty.Type.FRIENDS:
					if not friend:
						return _deny(DotError.CODE_FORBIDDEN, "Only the host's friends can join this party.", "party.join.deny.notFriend")
					if not bool(extra["friends_can_join"]):
						return _deny(DotError.CODE_FORBIDDEN, "This party is invite only.", "party.join.deny.needInvite")
			# The after-start lock is for walk-ins only; an invite is the host deciding by hand.
			if party.stage == DotParty.Stage.PLAYING:
				var late := bool(extra["join_after_start_friends"]) if friend else bool(extra["join_after_start"])
				if not late:
					return _deny(DotError.CODE_STATE, "This party has already started and is not taking new players.", "party.join.deny.started")

	var left := _leave_every_party(user_id)

	var row: DotPartyMember = null
	for m in party.roster:
		if m.user_id == user_id:
			row = m
	if row == null:
		row = DotPartyMember.of(user_id, str(names.get(user_id, user_id)))
		party.roster.append(row)
	row.state = DotPartyMember.State.JOINED
	# A host rejoining their own party is its host again.
	row.role = DotPartyMember.Role.HOST if party.host_id == user_id else (
		DotPartyMember.Role.CO_HOST if row.role == DotPartyMember.Role.CO_HOST else DotPartyMember.Role.MEMBER)
	row.joined_at = now()
	row.ready_at = 0
	row.connected_at = 0
	_seen["%s|%s" % [party_id, user_id]] = now()
	_evaluate_ready(party)
	return DotResult.success({"partyId": party_id, "role": row.role_name(), "leftPartyId": left if left != "" else null})


func leave(user_id: String, party_id: String) -> DotResult:
	var party := _live(party_id)
	if party == null:
		return DotResult.success({"left": false, "ended": false})
	var m := party.member(user_id)
	if m == null:
		return DotResult.success({"left": false, "ended": false})
	m.state = DotPartyMember.State.LEFT
	m.ready_at = 0
	m.connected_at = 0
	# The last one out ends it. The host leaving alone does not: hosts drop in and out, and
	# their party surviving that is the point of hosting one.
	var ended := party.size() == 0
	if ended:
		_end(party)
	else:
		_evaluate_ready(party)
	return DotResult.success({"left": true, "ended": ended})


func heartbeat(user_id: String, party_id: String) -> DotResult:
	var party := _live(party_id)
	if party == null or party.member(user_id) == null:
		return _deny(DotError.CODE_STATE, "You are not in that party.", "party.heartbeat.deny.member")
	_seen["%s|%s" % [party_id, user_id]] = now()
	return DotResult.success(null)


func kick(actor: String, party_id: String, target: String, ban: bool) -> DotResult:
	var party := _live(party_id)
	if party == null:
		return _deny(DotError.CODE_STATE, "That party has ended.", "party.join.deny.ended")
	var who := party.member(actor)
	var victim := party.member(target)
	if who == null or not who.can_manage():
		return _deny(DotError.CODE_FORBIDDEN, "Only the host or a co-host can do that.", "party.manage.deny.role")
	if victim == null:
		return _deny(DotError.CODE_STATE, "They are not in the party.", "party.kick.deny.member")
	if victim.role == DotPartyMember.Role.HOST or target == actor:
		return _deny(DotError.CODE_FORBIDDEN, "The host cannot be removed.", "party.kick.deny.host")
	if victim.role == DotPartyMember.Role.CO_HOST and who.role != DotPartyMember.Role.HOST:
		return _deny(DotError.CODE_FORBIDDEN, "Only the host can remove a co-host.", "party.kick.deny.cohost")
	victim.state = DotPartyMember.State.BANNED if ban else DotPartyMember.State.KICKED
	victim.ready_at = 0
	if ban:
		((_extra[party_id] as Dictionary)["bans"] as Dictionary)[target] = true
	_evaluate_ready(party)
	return DotResult.success(null)


func set_role(actor: String, party_id: String, target: String, role: DotPartyMember.Role) -> DotResult:
	var party := _live(party_id)
	if party == null or party.host_id != actor:
		return _deny(DotError.CODE_FORBIDDEN, "Only the host can change roles.", "party.manage.deny.role")
	if role == DotPartyMember.Role.HOST:
		return _deny(DotError.CODE_INVALID, "Hand the party over instead.", "party.role.deny.host")
	var m := party.member(target)
	if m == null or target == actor:
		return _deny(DotError.CODE_STATE, "They are not in the party.", "party.role.deny.member")
	m.role = role
	return DotResult.success(null)


func transfer_host(actor: String, party_id: String, target: String) -> DotResult:
	var party := _live(party_id)
	if party == null or party.host_id != actor:
		return _deny(DotError.CODE_FORBIDDEN, "Only the host can hand the party over.", "party.manage.deny.role")
	var next := party.member(target)
	if next == null or target == actor:
		return _deny(DotError.CODE_STATE, "They are not in the party.", "party.transfer.deny.member")
	for m in party.roster:
		if m.user_id == actor:
			m.role = DotPartyMember.Role.CO_HOST
	next.role = DotPartyMember.Role.HOST
	party.host_id = target
	return DotResult.success(null)


func end(actor: String, party_id: String) -> DotResult:
	var party := _live(party_id)
	if party == null:
		return DotResult.success(null)
	if party.host_id != actor:
		return _deny(DotError.CODE_FORBIDDEN, "Only the host can end the party.", "party.manage.deny.role")
	_end(party)
	return DotResult.success(null)


# --- Invites -----------------------------------------------------------------

func invite(actor: String, party_id: String, user_ids: PackedStringArray, message: String) -> DotResult:
	var party := _live(party_id)
	if party == null or party.member(actor) == null:
		return _deny(DotError.CODE_FORBIDDEN, "You are not in that party.", "party.invite.deny.member")
	if not party.can_manage(actor) and party.type != DotParty.Type.PUBLIC:
		return _deny(DotError.CODE_FORBIDDEN, "Only the host or a co-host can invite to this party.", "party.manage.deny.role")
	if user_ids.size() > INVITE_BATCH_MAX:
		return _deny(DotError.CODE_INVALID, "At most 25 people at once.", "party.invite.deny.batch")
	var made := PackedStringArray()
	for uid in user_ids:
		if party.member(uid) != null:
			continue
		var inv_id := str(_next_invite)
		_next_invite += 1
		_invites[inv_id] = {
			"id": inv_id, "partyId": party_id, "partyName": party.name, "inviterId": actor,
			"userId": uid, "status": "PENDING", "message": message,
		}
		made.append(inv_id)
	return DotResult.success(made)


func invites_for(user_id: String) -> DotResult:
	var out := []
	for inv in _invites.values():
		var d: Dictionary = inv
		if str(d["userId"]) == user_id and str(d["status"]) == "PENDING" and _live(str(d["partyId"])) != null:
			out.append(d.duplicate())
	return DotResult.success(out)


func respond_invite(user_id: String, invite_id: String, accept: bool) -> DotResult:
	var d: Dictionary = _invites.get(invite_id, {})
	if d.is_empty() or str(d["userId"]) != user_id or str(d["status"]) != "PENDING":
		return _deny(DotError.CODE_STATE, "That invite is no longer open.", "party.invite.deny.closed")
	if not accept:
		d["status"] = "DECLINED"
		return DotResult.success(null)
	return join(user_id, str(d["partyId"]))


# --- The ready round ---------------------------------------------------------

func start(actor: String, party_id: String, server_id: int) -> DotResult:
	var party := _live(party_id)
	if party == null or not party.can_manage(actor):
		return _deny(DotError.CODE_FORBIDDEN, "Only the host or a co-host can start.", "party.manage.deny.role")
	if server_id > 0:
		party.server_id = server_id
	if party.server_id <= 0 or not _servers.has(party.server_id):
		return _deny(DotError.CODE_STATE, "Pick a server first.", "party.ready.deny.server")
	var srv: Dictionary = _servers[party.server_id]
	party.stage = DotParty.Stage.READY
	party.connect_info = {"serverId": party.server_id, "serverName": srv["name"], "url": srv["url"]}
	for m in party.members():
		m.ready_at = 0
		m.connected_at = 0
	var extra: Dictionary = _extra[party_id]
	extra["ready_opened"] = now()
	extra["deadline"] = 0
	return DotResult.success(ready_view(actor, party_id).value)


func set_ready(user_id: String, party_id: String, is_ready: bool) -> DotResult:
	var party := _live(party_id)
	if party == null or party.member(user_id) == null:
		return _deny(DotError.CODE_STATE, "You are not in that party.", "party.ready.deny.member")
	if party.stage != DotParty.Stage.READY:
		return _deny(DotError.CODE_STATE, "There is no ready round open.", "party.ready.deny.stage")
	party.member(user_id).ready_at = now() if is_ready else 0
	_evaluate_ready(party)
	return ready_view(user_id, party_id)


func connected(user_id: String, party_id: String) -> DotResult:
	var party := _live(party_id)
	if party == null or party.member(user_id) == null:
		return _deny(DotError.CODE_STATE, "You are not in that party.", "party.ready.deny.member")
	party.member(user_id).connected_at = now()
	_seen["%s|%s" % [party_id, user_id]] = now()
	return DotResult.success(null)


func force_start(actor: String, party_id: String) -> DotResult:
	var party := _live(party_id)
	if party == null or not party.can_manage(actor):
		return _deny(DotError.CODE_FORBIDDEN, "Only the host or a co-host can start.", "party.manage.deny.role")
	if party.stage != DotParty.Stage.READY:
		return _deny(DotError.CODE_STATE, "There is no ready round open.", "party.ready.deny.stage")
	_start_match(party)
	return DotResult.success(null)


func cancel_ready(actor: String, party_id: String) -> DotResult:
	var party := _live(party_id)
	if party == null or not party.can_manage(actor):
		return _deny(DotError.CODE_FORBIDDEN, "Only the host or a co-host can do that.", "party.manage.deny.role")
	party.stage = DotParty.Stage.LOBBY
	party.connect_info = {}
	(_extra[party_id] as Dictionary)["deadline"] = 0
	return DotResult.success(null)


func ready_view(user_id: String, party_id: String) -> DotResult:
	var party: DotParty = _parties.get(party_id)
	if party == null:
		return _deny(DotError.CODE_STATE, "No such party.", "party.deny.missing")
	var extra: Dictionary = _extra[party_id]
	var r := DotPartyReady.new()
	r.stage = party.stage
	r.total = party.size()
	r.ready = party.ready_count()
	r.pct = 0 if r.total == 0 else int(round(100.0 * r.ready / r.total))
	r.auto_pct = int(extra["auto_pct"])
	r.auto_sec = int(extra["auto_sec"])
	var deadline := int(extra["deadline"])
	r.countdown_sec = maxi(0, deadline - now()) if deadline > 0 else -1
	r.connect_info = party.connect_info.duplicate()
	r.started = party.stage == DotParty.Stage.PLAYING
	var me := party.member(user_id)
	r.me = {
		"isMember": me != null,
		"ready": me != null and me.is_ready(),
		"connected": me != null and me.has_connected(),
		"canManage": me != null and me.can_manage(),
	}
	return DotResult.success(r)


## Timers: stale members leave, armed countdowns start rounds, bookings expire. The site
## does these in worker crons; a hub needs a caller, and [DotPartyClient] is not it — a
## hub is shared, so whoever owns it ticks it.
func tick() -> void:
	var t := now()
	for p in _parties.values():
		var party: DotParty = p
		if not party.is_live():
			continue
		for m in party.members():
			var seen := int(_seen.get("%s|%s" % [party.id, m.user_id], t))
			if t - seen > MEMBER_STALE_SEC:
				leave(m.user_id, party.id)
		if not party.is_live():
			continue
		var extra: Dictionary = _extra[party.id]
		if party.stage == DotParty.Stage.READY and int(extra["deadline"]) > 0 and t >= int(extra["deadline"]):
			_start_match(party)
	for r in _reservations:
		if r.status == DotPartyReservation.Status.ACTIVE and t >= r.ends_at:
			r.status = DotPartyReservation.Status.ENDED
			r.released_at = r.ends_at
		elif r.status == DotPartyReservation.Status.PENDING and t >= r.ends_at:
			r.status = DotPartyReservation.Status.EXPIRED


# --- Reservations ------------------------------------------------------------

func reservation_offer(party_id: String, server_id: int) -> DotResult:
	var srv: Dictionary = _servers.get(server_id, {})
	if srv.is_empty():
		return _deny(DotError.CODE_STATE, "No such server.", "party.reserve.deny.server")
	var policy: DotPartyReservePolicy = srv["policy"]
	return DotResult.success(policy.offer(
		now(), party_id, int(srv["humans"]), _held(server_id), _last_for(party_id, server_id), bool(srv["online"])
	))


func reserve(actor: String, party_id: String, server_id: int, minutes: int, want_private: bool) -> DotResult:
	var party := _live(party_id)
	if party == null or not party.can_manage(actor):
		return _deny(DotError.CODE_FORBIDDEN, "Only the host or a co-host can book a server.", "party.manage.deny.role")
	var offered := reservation_offer(party_id, server_id)
	if not offered.ok:
		return offered
	var policy: DotPartyReservePolicy = (_servers[server_id] as Dictionary)["policy"]
	var granted := policy.grant(now(), minutes, want_private, offered.value)
	if not granted.ok:
		return granted
	var g: Dictionary = granted.value
	var r := DotPartyReservation.new()
	r.id = str(_next_reservation)
	_next_reservation += 1
	r.server_id = server_id
	r.party_id = party_id
	r.requested_by = actor
	r.is_private = bool(g["private"])
	r.starts_at = int(g["starts_at"])
	r.ends_at = int(g["ends_at"])
	r.status = DotPartyReservation.Status.ACTIVE if policy.auto_approve else DotPartyReservation.Status.PENDING
	_reservations.append(r)
	if r.status == DotPartyReservation.Status.ACTIVE:
		party.server_id = server_id
	return DotResult.success(r)


## The owner's half of a hand-approved booking.
func decide(reservation_id: String, approve: bool) -> DotResult:
	for r in _reservations:
		if r.id == reservation_id and r.status == DotPartyReservation.Status.PENDING:
			r.status = DotPartyReservation.Status.ACTIVE if approve else DotPartyReservation.Status.DENIED
			return DotResult.success(r)
	return _deny(DotError.CODE_STATE, "That booking is not waiting for a decision.", "party.reserve.deny.state")


func cancel_reservation(actor: String, reservation_id: String) -> DotResult:
	for r in _reservations:
		if r.id != reservation_id:
			continue
		var party: DotParty = _parties.get(r.party_id)
		if party == null or not party.can_manage(actor):
			return _deny(DotError.CODE_FORBIDDEN, "Only the host or a co-host can cancel a booking.", "party.manage.deny.role")
		if r.status == DotPartyReservation.Status.ACTIVE:
			r.status = DotPartyReservation.Status.ENDED
			r.released_at = now()
		elif r.status == DotPartyReservation.Status.PENDING:
			r.status = DotPartyReservation.Status.CANCELLED
		return DotResult.success(r)
	return _deny(DotError.CODE_STATE, "No such booking.", "party.reserve.deny.missing")


## What a game server asks: the booking it is under now, and the party it is for.
## Value: [code]{reservation, party}[/code] or null. See [DotPartyReservations].
func active_for_server(server_id: int) -> DotResult:
	var t := now()
	for r in _reservations:
		if r.server_id == server_id and r.is_active_at(t):
			var party: DotParty = _parties.get(r.party_id)
			return DotResult.success({"reservation": r, "party": party.copy() if party != null else null})
	return DotResult.success(null)


func mine(user_id: String) -> DotResult:
	for p in _parties.values():
		var party: DotParty = p
		if party.is_live() and party.member(user_id) != null:
			return DotResult.success(party.copy())
	return DotResult.success(null)


func fetch(party_id: String) -> DotResult:
	var party: DotParty = _parties.get(party_id)
	if party == null:
		return _deny(DotError.CODE_STATE, "No such party.", "party.deny.missing")
	return DotResult.success(party.copy())


# --- Internals ---------------------------------------------------------------

func _live(party_id: String) -> DotParty:
	var party: DotParty = _parties.get(party_id)
	if party == null or not party.is_live():
		return null
	return party


func _end(party: DotParty) -> void:
	party.end_time = now()
	for r in _reservations:
		if r.party_id == party.id and (r.status == DotPartyReservation.Status.ACTIVE or r.status == DotPartyReservation.Status.PENDING):
			r.status = DotPartyReservation.Status.ENDED if r.status == DotPartyReservation.Status.ACTIVE else DotPartyReservation.Status.CANCELLED
			r.released_at = now()


func _leave_every_party(user_id: String) -> String:
	var left := ""
	for p in _parties.values():
		var party: DotParty = p
		if party.is_live() and party.member(user_id) != null:
			leave(user_id, party.id)
			left = party.id
	return left


func _start_match(party: DotParty) -> void:
	party.stage = DotParty.Stage.PLAYING
	(_extra[party.id] as Dictionary)["deadline"] = 0


## The site's rule: everybody ready starts it; a threshold share arms a countdown once;
## dropping below the threshold disarms it.
func _evaluate_ready(party: DotParty) -> void:
	if party.stage != DotParty.Stage.READY:
		return
	var extra: Dictionary = _extra[party.id]
	var ready := party.ready_count()
	var total := party.size()
	if total > 0 and ready >= total:
		_start_match(party)
		return
	if DotPartyReady.threshold_met(int(extra["auto_pct"]), ready, total):
		if int(extra["deadline"]) == 0:
			extra["deadline"] = now() + int(extra["auto_sec"])
		return
	extra["deadline"] = 0


func _consume_invite(party_id: String, user_id: String, token: String) -> bool:
	for inv in _invites.values():
		var d: Dictionary = inv
		if str(d["partyId"]) != party_id or str(d["status"]) != "PENDING":
			continue
		if str(d["userId"]) == user_id or (token != "" and str(d.get("token", "")) == token):
			d["status"] = "ACCEPTED"
			return true
	return false


func _is_friend(user_id: String, party: DotParty) -> bool:
	if not friends_fn.is_valid():
		return false
	return bool(friends_fn.call(user_id, party.host_id))


func _held(server_id: int) -> DotPartyReservation:
	var t := now()
	var best: DotPartyReservation = null
	for r in _reservations:
		if r.server_id != server_id or r.ends_at <= t:
			continue
		if r.status != DotPartyReservation.Status.ACTIVE and r.status != DotPartyReservation.Status.PENDING:
			continue
		if best == null or r.ends_at > best.ends_at:
			best = r
	return best


func _last_for(party_id: String, server_id: int) -> DotPartyReservation:
	var best: DotPartyReservation = null
	for r in _reservations:
		if r.party_id != party_id or r.server_id != server_id:
			continue
		if r.status != DotPartyReservation.Status.ACTIVE and r.status != DotPartyReservation.Status.ENDED:
			continue
		if best == null or r.ends_at > best.ends_at:
			best = r
	return best


static func _deny(code: String, message: String, key: String) -> DotResult:
	return DotResult.fail(code, message, key)

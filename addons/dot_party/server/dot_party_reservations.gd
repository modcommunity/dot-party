class_name DotPartyReservations
extends Node

## A game server keeping the promise the website made when a party booked it.
##
## [b]Until this, nothing kept it.[/b] website-city lets a party book a server for an
## evening, privately if the owner allows — and no integration route ever told the game
## server, so a "private" booking admitted anybody who found the address. This node is the
## server's half: it learns the booking (from the backbone, from a local hub, or from the
## owner at the console), and it answers the admission question dot-server already asks.
##
## [b]It admits through [code]dot_ban_source[/code], chained.[/b] That is the seam dot-server
## consults on every join, and dot-moderation and dot-server-security's ban feeds already
## share it by chaining. This does the same — whatever was registered before is kept and
## asked as well — so installing parties does not quietly switch off anybody's bans. The
## trap in that seam is ordering: the previous holder is captured BEFORE registering, or
## this node finds itself and every admission recurses until the stack gives out.
##
## [b]Two shapes, as on the site.[/b] A private booking admits the party and nobody else.
## A public one leaves the server open but [i]holds seats[/i] for members who have not
## arrived yet, for [member DotPartyConfig.seat_hold_sec] — the join-together window.
## Without that, eight friends who booked a server lose it to whoever connects in the
## thirty seconds it takes them all to load a map, which is the exact failure the site's
## own reservation rules say the feature exists to prevent.
##
## [b]The address-only pass is not judged.[/b] dot-server asks twice: once with an address,
## before anybody has said who they are, and once with both. A booking is about people, so
## the first pass is always admitted here and the second is where the decision is.
##
## [b]A member is recognised by uid, never by name.[/b] A session's uid is
## [code]backbone:<user id>[/code] after dot-auth, and the party's roster carries user ids.
## A display name can be chosen by anybody; matching on it would let a stranger in by
## calling themselves the host.

const CHANNEL := "party.reserve"
const SERVICE := &"dot_party_reservations"

## The seam dot-server asks. dot-moderation and dot-server-security publish the same name.
const BAN_SOURCE := &"dot_ban_source"

signal reservation_started(reservation: DotPartyReservation, party: DotParty)
signal reservation_ending(reservation: DotPartyReservation, seconds_left: int)
## [param reason]: "expired", "released", "empty", "cancelled".
signal reservation_ended(reservation: DotPartyReservation, reason: String)
signal admission_refused(uid: String, reason: String)

@export var config: DotPartyConfig = null

## This server's terms, for bookings made here rather than on the website.
@export var policy: DotPartyReservePolicy = null

## Also consult whatever held [code]dot_ban_source[/code] before this node. Off replaces the
## ban list's enforcement rather than adding to it, which is almost never what anybody wants.
@export var chain_previous: bool = true

## This server's id on the backbone, for bookings made through a hub.
@export var server_id: int = 0

## [code]func() -> Vector2i[/code]: occupied seats and the maximum. Needed for a public
## booking to hold seats; without it a public booking holds none.
var seats_fn: Callable = Callable()

## [code]func(uid: String) -> bool[/code]: people admitted to a private booking regardless,
## usually admins with the reservation flag. An owner locked out of their own server by a
## party is a support ticket.
var bypass_fn: Callable = Callable()

## [code]func() -> DotResult[/code] (awaited): the booking now, as [code]{reservation, party}[/code]
## or null. See [method use_backbone] and [method use_hub].
var fetch_fn: Callable = Callable()

## Unix seconds. The suite replaces it.
var now_fn: Callable = func() -> int: return int(Time.get_unix_time_from_system())

var previous_source: Object = null

## The booking in force, or null.
var current: DotPartyReservation = null

## The party it is for, as last fetched.
var party: DotParty = null

var _arrived: Dictionary = {}
var _warned: bool = false
var _empty_since: int = 0
var _since_sync: float = 0.0
var _since_tick: float = 0.0
var _refusals: int = 0


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if config == null:
		config = DotPartyConfig.new()
	if policy == null:
		policy = DotPartyReservePolicy.new()

	var existing := DotRegistry.get_service(BAN_SOURCE)
	if chain_previous and existing != null and existing != self and is_instance_valid(existing) \
			and existing.has_method("check_admission"):
		previous_source = existing
		DotLog.info(CHANNEL, "chaining to the ban source that was already registered", {"was": existing.get_class()})

	DotRegistry.register(SERVICE, self)
	DotRegistry.register(BAN_SOURCE, self)


func _exit_tree() -> void:
	DotRegistry.unregister_instance(SERVICE, self)
	DotRegistry.unregister_instance(BAN_SOURCE, self)
	# Hand the seam back rather than leaving it empty, so removing parties at runtime does
	# not also remove the bans.
	if previous_source != null and is_instance_valid(previous_source):
		DotRegistry.register(BAN_SOURCE, previous_source)


func _process(delta: float) -> void:
	_since_tick += delta
	_since_sync += delta
	if _since_tick >= 1.0:
		_since_tick = 0.0
		tick()
	if fetch_fn.is_valid() and _since_sync >= config.reservation_sync_sec:
		_since_sync = 0.0
		sync()


# --- The seam dot-server asks ------------------------------------------------

func check_admission(uid: String, address: String) -> DotResult:
	var mine := judge(uid)
	if not mine.ok:
		_refusals += 1
		admission_refused.emit(uid, mine.error.message)
		DotLog.info(CHANNEL, "refused by a party booking", {"uid": uid, "reason": mine.error.detail})
		return mine
	if previous_source != null and is_instance_valid(previous_source):
		var chained: Variant = previous_source.call("check_admission", uid, address)
		if chained is DotResult:
			return chained as DotResult
	return DotResult.success(true)


## The booking's answer alone, without the chain.
func judge(uid: String) -> DotResult:
	var now := _now()
	if current == null or not current.is_active_at(now):
		return DotResult.success(true)
	if uid.strip_edges() == "":
		return DotResult.success(true)
	if is_member(uid):
		return DotResult.success(true)
	if bypass_fn.is_valid() and bool(bypass_fn.call(uid)):
		return DotResult.success(true)

	if current.is_private:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"This server is booked for a private party until %s UTC." % _clock(current.ends_at),
			"party.reserve.private"
		)

	var owed := seats_owed(now)
	if owed > 0 and seats_fn.is_valid():
		var seats: Vector2i = seats_fn.call()
		var free := seats.y - seats.x
		if free <= owed:
			return DotResult.fail(
				DotError.CODE_CONFLICT,
				"The last seats are held for a party that is on its way. Try again in a few minutes.",
				"party.reserve.held"
			)
	return DotResult.success(true)


func is_member(uid: String) -> bool:
	return party != null and party.server_uids().has(uid)


## Seats still held for members who have not arrived, or 0 once the hold window is over.
func seats_owed(now: int) -> int:
	if current == null or current.is_private or party == null:
		return 0
	if now >= current.starts_at + int(config.seat_hold_sec):
		return 0
	var owed := 0
	for uid in party.server_uids():
		if not _arrived.has(uid):
			owed += 1
	return owed


# --- What the game tells it --------------------------------------------------

## A session was admitted. The game calls this from its join handler.
func note_arrival(uid: String) -> void:
	if is_member(uid):
		_arrived[uid] = true
		_empty_since = 0


func note_departure(uid: String) -> void:
	_arrived.erase(uid)
	if current != null and _arrived.is_empty() and _empty_since == 0:
		_empty_since = _now()


func arrived_count() -> int:
	return _arrived.size()


# --- Where bookings come from ------------------------------------------------

## Books this server for [param p] here, under [member policy]. For a LAN, or an owner at
## the console; a website booking arrives through [method sync] instead.
func book(p: DotParty, minutes: int, want_private: bool) -> DotResult:
	var now := _now()
	var humans := 0
	if seats_fn.is_valid():
		humans = (seats_fn.call() as Vector2i).x
	var held: DotPartyReservation = current if current != null and current.is_active_at(now) else null
	var offered := policy.offer(now, p.id, humans, held)
	var granted := policy.grant(now, minutes, want_private, offered)
	if not granted.ok:
		return granted
	var g: Dictionary = granted.value
	var r := DotPartyReservation.new()
	r.id = "local-%d" % now
	r.server_id = server_id
	r.party_id = p.id
	r.is_private = bool(g["private"])
	r.starts_at = int(g["starts_at"])
	r.ends_at = int(g["ends_at"])
	r.status = DotPartyReservation.Status.ACTIVE
	apply(r, p)
	return DotResult.success(r)


## Puts a booking in force, or with null lifts the one in force.
func apply(r: DotPartyReservation, p: DotParty) -> void:
	var now := _now()
	if r == null or not r.is_active_at(now):
		if current != null:
			_end("released")
		return
	var is_new := current == null or current.id != r.id
	current = r
	party = p
	if is_new:
		_arrived.clear()
		_warned = false
		_empty_since = 0
		DotLog.info(CHANNEL, "booked for a party", {
			"party": r.party_id, "private": r.is_private, "until": _clock(r.ends_at),
		})
		reservation_started.emit(r, p)


## Asks [member fetch_fn] for the booking now and applies it.
func sync() -> DotResult:
	if not fetch_fn.is_valid():
		return DotResult.fail(DotError.CODE_STATE, "nowhere to fetch bookings from")
	var res: Variant = await fetch_fn.call()
	if not (res is DotResult):
		return DotResult.fail(DotError.CODE_INTERNAL, "fetch_fn did not return a DotResult")
	var got: DotResult = res
	if not got.ok:
		# Keep the booking we have. A backbone outage must not open a private server.
		return got
	if got.value == null:
		apply(null, null)
		return got
	var d: Dictionary = got.value
	apply(d.get("reservation") as DotPartyReservation, d.get("party") as DotParty)
	return got


## Fetches bookings from the backbone as this server, through any object with
## [code]get_integration(path, query)[/code] — dot-auth's [code]DotBackboneClient[/code].
##
## The route, [code]GET party/reservation[/code], is one website-city does not serve yet;
## it is specified in this repository's [code]docs/backbone-contract.md[/code].
func use_backbone(client: Object) -> void:
	fetch_fn = func() -> DotResult:
		var res: DotResult = await client.call("get_integration", "party/reservation", {})
		if not res.ok:
			return res
		return DotPartyReservations.parse_backbone(res.value)


## Fetches bookings from an in-process hub, as server [member server_id].
func use_hub(hub: DotPartyLocalHub) -> void:
	fetch_fn = func() -> DotResult:
		return hub.active_for_server(server_id)


## Reads [code]{ok, reservation, party, members}[/code]. Either may be null.
static func parse_backbone(value: Variant) -> DotResult:
	if not (value is Dictionary):
		return DotResult.fail(DotError.CODE_PARSE, "a reservation answer that is not an object")
	var d: Dictionary = value
	if d.get("reservation") == null:
		return DotResult.success(null)
	if not (d["reservation"] is Dictionary):
		return DotResult.fail(DotError.CODE_PARSE, "reservation is not an object")
	var r := DotPartyReservation.from_dict(d["reservation"] as Dictionary)
	if not r.ok:
		return r
	var p: DotParty = null
	if d.get("party") is Dictionary:
		var parsed := DotParty.from_dict({"party": d["party"], "members": d.get("members", [])})
		if not parsed.ok:
			return parsed
		p = parsed.value
	return DotResult.success({"reservation": r.value, "party": p})


# --- Time ----------------------------------------------------------------------

## Expiry, the warning, and releasing a booking its party has abandoned.
func tick() -> void:
	if current == null:
		return
	var now := _now()
	if now >= current.ends_at:
		_end("expired")
		return
	var left := current.seconds_left(now)
	if not _warned and config.reservation_warn_sec > 0.0 and left <= int(config.reservation_warn_sec):
		_warned = true
		reservation_ending.emit(current, left)
	if config.release_when_empty_sec > 0.0 and _empty_since > 0 \
			and now - _empty_since >= int(config.release_when_empty_sec):
		_end("empty")


func release(reason: String = "released") -> void:
	if current != null:
		_end(reason)


func _end(reason: String) -> void:
	var r := current
	current = null
	party = null
	_arrived.clear()
	_empty_since = 0
	DotLog.info(CHANNEL, "booking over", {"party": r.party_id, "reason": reason})
	reservation_ended.emit(r, reason)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	if current == null:
		out.append("party booking: none")
	else:
		out.append(current.describe(_now()))
		out.append("  %d of %d members here, %d seats held, %d refused" % [
			_arrived.size(), party.size() if party != null else 0, seats_owed(_now()), _refusals,
		])
	out.append_array(policy.describe_lines() if policy != null else PackedStringArray())
	return out


func _now() -> int:
	return int(now_fn.call())


static func _clock(t: int) -> String:
	return Time.get_datetime_string_from_unix_time(t, true).substr(11, 5)

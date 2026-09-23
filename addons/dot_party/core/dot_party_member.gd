class_name DotPartyMember
extends RefCounted

## One person in a party, in the backbone's own vocabulary.
##
## The fields and their names follow website-city's [code]PartyMember[/code] and the
## JSON its routes answer with, deliberately. A game-side model that renamed them would
## need a translation table, and a translation table is a second copy of a schema that
## changes on the site's schedule rather than ours.

enum Role { HOST, CO_HOST, MEMBER }
enum State { JOINED, LEFT, KICKED, BANNED }

## How sure the backbone is that this member is actually on the game server. The site
## infers it by matching the server's player list against the roster, and an ambiguous
## match counts as nobody.
enum Presence { NONE, LIKELY, AMBIGUOUS, CONFIRMED }

const ROLE_NAMES := ["HOST", "CO_HOST", "MEMBER"]
const STATE_NAMES := ["JOINED", "LEFT", "KICKED", "BANNED"]
const PRESENCE_NAMES := ["NONE", "LIKELY", "AMBIGUOUS", "CONFIRMED"]

## The backbone's user id. A game server sees it as [code]backbone:<user_id>[/code].
var user_id: String = ""
var display_name: String = ""

## The name they use in game, which the site matches reports against.
var game_name: String = ""

var role: Role = Role.MEMBER
var state: State = State.JOINED
var presence: Presence = Presence.NONE

## Unix seconds. 0 means not.
var joined_at: int = 0
var ready_at: int = 0
var connected_at: int = 0

var score: int = 0
var kills: int = 0
var deaths: int = 0
var assist: int = 0


static func of(p_user_id: String, p_name: String, p_role: Role = Role.MEMBER) -> DotPartyMember:
	var m := DotPartyMember.new()
	m.user_id = p_user_id
	m.display_name = p_name
	m.game_name = p_name
	m.role = p_role
	return m


func is_joined() -> bool:
	return state == State.JOINED


func is_ready() -> bool:
	return ready_at > 0


## Not [code]is_connected[/code]: that is [method Object.is_connected], and shadowing it
## is a parse error reported against every file that uses this one.
func has_connected() -> bool:
	return connected_at > 0


## Host and co-host may manage the party: kick, invite, start a round.
func can_manage() -> bool:
	return role == Role.HOST or role == Role.CO_HOST


## The uid a dot-server session carries for this person.
func server_uid() -> String:
	return "backbone:%s" % user_id


func role_name() -> String:
	return ROLE_NAMES[role]


static func parse_role(s: String) -> Role:
	var i := ROLE_NAMES.find(s.to_upper())
	return Role.MEMBER if i < 0 else i as Role


static func parse_state(s: String) -> State:
	var i := STATE_NAMES.find(s.to_upper())
	return State.JOINED if i < 0 else i as State


static func parse_presence(s: String) -> Presence:
	var i := PRESENCE_NAMES.find(s.to_upper())
	return Presence.NONE if i < 0 else i as Presence


## Reads a member row as any of the backbone's party routes return it.
##
## Tolerant of absent fields, strict about the one that matters: a member with no user id
## cannot be matched against anybody and is refused rather than kept as a ghost.
static func from_dict(d: Dictionary) -> DotResult:
	var m := DotPartyMember.new()
	m.user_id = str(d.get("userId", d.get("user_id", "")))
	if m.user_id == "":
		return DotResult.fail(DotError.CODE_PARSE, "a party member with no user id", str(d))
	m.display_name = str(d.get("displayName", d.get("display_name", "")))
	m.game_name = str(d.get("gameName", d.get("game_name", m.display_name)))
	if d.get("gameName") == null and d.has("gameName"):
		m.game_name = m.display_name
	m.role = parse_role(str(d.get("role", "MEMBER")))
	m.state = parse_state(str(d.get("state", "JOINED")))
	m.presence = parse_presence(str(d.get("presence", "NONE")))
	m.joined_at = DotPartyMember.parse_time(d.get("joinedAt", d.get("joined_at")))
	m.ready_at = DotPartyMember.parse_time(d.get("readyAt", d.get("ready_at")))
	m.connected_at = DotPartyMember.parse_time(d.get("connectedAt", d.get("connected_at")))
	m.score = int(d.get("score", 0))
	m.kills = int(d.get("kills", 0))
	m.deaths = int(d.get("deaths", 0))
	m.assist = int(d.get("assist", 0))
	return DotResult.success(m)


func to_dict() -> Dictionary:
	return {
		"userId": user_id,
		"displayName": display_name,
		"gameName": game_name,
		"role": ROLE_NAMES[role],
		"state": STATE_NAMES[state],
		"presence": PRESENCE_NAMES[presence],
		"joinedAt": DotPartyMember.format_time(joined_at),
		"readyAt": DotPartyMember.format_time(ready_at),
		"connectedAt": DotPartyMember.format_time(connected_at),
		"score": score,
		"kills": kills,
		"deaths": deaths,
		"assist": assist,
	}


func copy() -> DotPartyMember:
	var parsed := DotPartyMember.from_dict(to_dict())
	return parsed.value


## An ISO 8601 string, a number of Unix seconds, or null, as Unix seconds (0 for none).
##
## The backbone sends ISO strings; a local hub and a suite send numbers. Both, because the
## alternative is two parsers and the one that is not tested drifting.
static func parse_time(v: Variant) -> int:
	if v == null:
		return 0
	if v is int or v is float:
		return int(v)
	var s := str(v).strip_edges()
	if s == "":
		return 0
	if s.is_valid_int():
		return s.to_int()
	# Time.get_unix_time_from_datetime_string wants no fraction and no zone.
	var core := s.replace("Z", "")
	var dot := core.find(".")
	if dot >= 0:
		core = core.substr(0, dot)
	var plus := core.find("+", 10)
	if plus >= 0:
		core = core.substr(0, plus)
	return int(Time.get_unix_time_from_datetime_string(core))


## Unix seconds as the ISO string the backbone sends, or null for none.
static func format_time(t: int) -> Variant:
	if t <= 0:
		return null
	return Time.get_datetime_string_from_unix_time(t) + "Z"

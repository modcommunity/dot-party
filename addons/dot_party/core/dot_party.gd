class_name DotParty
extends RefCounted

## A party: people who play together, and what they are doing right now.
##
## [b]The backbone owns it; this is a copy.[/b] website-city is where a party is created,
## joined, invited to and ended, and every client and server holds a snapshot that is only
## as fresh as its last poll. So nothing in this class decides anything — it describes, and
## [DotPartyBackend] is where a change is asked for. A game that edited a snapshot and
## treated that as the party would be the second copy that goes stale, which is the bug
## dot-player was written to remove.
##
## [b]The id is a decimal string.[/b] The site's id is a 64-bit integer and GDScript's
## [code]int[/code] is too, but JSON is not: a number past 2^53 arrives rounded, and the
## rounded id names somebody else's party. The site sends it as a string for that reason
## and it stays one here.
##
## [b]The stage is the join-together state machine.[/b] LOBBY is people gathering;
## SEARCHING is the site looking for a server; READY is a server chosen and everybody
## connecting to it at once; PLAYING is the round under way. The order on the wire is not
## that order — READY was appended to the site's enum last — so it is always carried by
## name here, never by number.

enum Stage { LOBBY, SEARCHING, READY, PLAYING }
enum Type { PUBLIC, PUBLIC_PASSWORD, FRIENDS, PRIVATE }

const STAGE_NAMES := ["LOBBY", "SEARCHING", "READY", "PLAYING"]
const TYPE_NAMES := ["PUBLIC", "PUBLIC_PASSWORD", "FRIENDS", "PRIVATE"]

## The site's limits, mirrored so a client can refuse before it asks.
const MIN_USERS := 2
const MAX_USERS_CAP := 256
const NAME_MAX := 128
## The longest decimal a 64-bit id can be.
const ID_MAX_LENGTH := 20

var id: String = ""
var name: String = ""
var type: Type = Type.PUBLIC
var tech_type: String = ""
var max_users: int = 8
var stage: Stage = Stage.LOBBY

var host_id: String = ""
var app_id: int = 0

## The server the party is on or heading to. 0 for none.
var server_id: int = 0

var map_name: String = ""
var game_mode: String = ""

## Unix seconds. [member end_time] 0 is a live party, which is the site's only authority
## on liveness — a stage is not.
var start_time: int = 0
var end_time: int = 0

## Everybody the snapshot saw, including those who left. [method members] is who is in it.
var roster: Array[DotPartyMember] = []

## Where to connect when the stage is READY: [code]{serverId, serverName, url}[/code], or
## empty. The URL is the site's resolved connect template for the app. Not called
## [code]connect[/code], because a property may not shadow [method Object.connect] and the
## error for that is reported against whichever file USES it.
var connect_info: Dictionary = {}


static func is_id(s: String) -> bool:
	if s == "" or s.length() > ID_MAX_LENGTH:
		return false
	for ch in s:
		if ch < "0" or ch > "9":
			return false
	return true


func is_live() -> bool:
	return end_time <= 0


## Members who are in the party now.
func members() -> Array[DotPartyMember]:
	var out: Array[DotPartyMember] = []
	for m in roster:
		if m.is_joined():
			out.append(m)
	return out


func size() -> int:
	return members().size()


func is_full() -> bool:
	return size() >= max_users


func member(user_id: String) -> DotPartyMember:
	for m in roster:
		if m.user_id == user_id and m.is_joined():
			return m
	return null


func has_member(user_id: String) -> bool:
	return member(user_id) != null


func host() -> DotPartyMember:
	for m in members():
		if m.role == DotPartyMember.Role.HOST:
			return m
	return null


## Whether [param user_id] may manage the party. Host and co-host.
func can_manage(user_id: String) -> bool:
	var m := member(user_id)
	return m != null and m.can_manage()


## The uids a dot-server session will carry for everybody in the party.
func server_uids() -> PackedStringArray:
	var out := PackedStringArray()
	for m in members():
		out.append(m.server_uid())
	return out


## Ready among joined members, as the site counts it.
func ready_count() -> int:
	var n := 0
	for m in members():
		if m.is_ready():
			n += 1
	return n


func stage_name() -> String:
	return STAGE_NAMES[stage]


static func parse_stage(s: String) -> Stage:
	var i := STAGE_NAMES.find(s.to_upper())
	return Stage.LOBBY if i < 0 else i as Stage


static func parse_type(s: String) -> Type:
	var i := TYPE_NAMES.find(s.to_upper())
	return Type.PUBLIC if i < 0 else i as Type


## Reads what the backbone sends: either [code]{party, members}[/code], as its
## [code]GET party/{id}[/code] answers, or a flat party object with a [code]members[/code]
## list in it.
static func from_dict(d: Dictionary) -> DotResult:
	var body: Dictionary = d
	var rows: Variant = d.get("members", [])
	if d.get("party") is Dictionary:
		body = d["party"]
		if not (rows is Array) or (rows as Array).is_empty():
			rows = body.get("members", [])

	var p := DotParty.new()
	p.id = str(body.get("id", ""))
	if not DotParty.is_id(p.id):
		return DotResult.fail(DotError.CODE_PARSE, "a party id is a decimal string of up to 20 digits", p.id)
	p.name = str(body.get("name", "")) if body.get("name") != null else ""
	p.type = DotParty.parse_type(str(body.get("type", "PUBLIC")))
	p.tech_type = str(body.get("techType", "")) if body.get("techType") != null else ""
	p.max_users = int(body.get("maxUsers", 8))
	p.stage = DotParty.parse_stage(str(body.get("stage", "LOBBY")))
	p.host_id = str(body.get("hostId", "")) if body.get("hostId") != null else ""
	p.app_id = int(body.get("appId", 0)) if body.get("appId") != null else 0
	p.server_id = int(body.get("serverId", 0)) if body.get("serverId") != null else 0
	p.map_name = str(body.get("mapName", "")) if body.get("mapName") != null else ""
	p.game_mode = str(body.get("gameMode", "")) if body.get("gameMode") != null else ""
	p.start_time = DotPartyMember.parse_time(body.get("startTime"))
	p.end_time = DotPartyMember.parse_time(body.get("endTime"))
	if body.get("connect") is Dictionary:
		p.connect_info = (body["connect"] as Dictionary).duplicate()

	if rows is Array:
		for r in rows:
			if not (r is Dictionary):
				continue
			var parsed := DotPartyMember.from_dict(r as Dictionary)
			if not parsed.ok:
				return parsed.wrap("party %s" % p.id)
			p.roster.append(parsed.value)

	# The host is a role on a member AND an id on the party. The site keeps both, and a
	# snapshot that disagreed with itself would have two answers to "who can kick".
	if p.host_id != "":
		for m in p.roster:
			if m.user_id == p.host_id and m.role != DotPartyMember.Role.HOST and m.is_joined():
				m.role = DotPartyMember.Role.HOST
	return DotResult.success(p)


func to_dict() -> Dictionary:
	var rows := []
	for m in roster:
		rows.append(m.to_dict())
	return {
		"id": id,
		"name": name,
		"type": TYPE_NAMES[type],
		"techType": tech_type,
		"maxUsers": max_users,
		"stage": STAGE_NAMES[stage],
		"hostId": host_id,
		"appId": app_id,
		"serverId": server_id if server_id > 0 else null,
		"mapName": map_name,
		"gameMode": game_mode,
		"startTime": DotPartyMember.format_time(start_time),
		"endTime": DotPartyMember.format_time(end_time),
		"users": size(),
		"connect": connect_info,
		"members": rows,
	}


func copy() -> DotParty:
	var parsed := DotParty.from_dict(to_dict())
	return parsed.value


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("party %s \"%s\": %s, %d/%d%s" % [
		id, name, stage_name(), size(), max_users, "" if is_live() else " (ended)",
	])
	for m in members():
		out.append("  %-8s %s%s%s" % [
			m.role_name(), m.display_name,
			" ready" if m.is_ready() else "",
			" connected" if m.has_connected() else "",
		])
	return out

extends Node

## Exercises dot-party with no network: four people, a hub, a game server and a fake backbone.
##
## [b]The backbone's shapes are checked against the site's own documentation.[/b] Section
## 1 parses the JSON printed in website-city's integration API document, field for field,
## because a parser checked only against JSON this suite wrote itself would agree with
## itself about a shape the site does not send.
##
## [b]Section 7 is the one to keep.[/b] It is the promise nothing kept before this addon:
## that a party which booked a server privately is the only party that gets in, and that
## a public booking holds seats while its members are still loading.
##
## [codeblock]
## godot --headless --path . res://examples/party_selftest.tscn
## [/codeblock]

const SECTIONS := 9
const CHECKS := 135

var _passed := 0
var _failed := 0
var _section_count := 0

## Captured by lambdas, so a container rather than a scalar.
var _now: Array[int] = [1_790_000_000]


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	await _run()


func _run() -> void:
	_line("dot-party self-test")
	_line("")

	_test_backbone_shapes()
	_test_membership()
	_test_roles()
	_test_ready_round()
	await _test_client()
	_test_policy()
	await _test_reservations()
	await _test_server_reporting()
	await _test_app_backend()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return

	if _passed + _failed != CHECKS:
		_line(
			"ERROR: %d checks ran, %d expected. A section aborted part-way."
			% [_passed + _failed, CHECKS]
		)
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


# --- 1 ----------------------------------------------------------------------

## `GET /party/{id}`, verbatim from website-city's docs/api/integration-api.md.
const SITE_PARTY := """{
  "ok": true,
  "party": {
    "id": "4471", "name": "Ranked queue", "type": "PUBLIC", "techType": "THIRD_PARTY_SUPPORTED",
    "maxUsers": 10, "users": 4, "startTime": "2026-07-29T20:00:00.000Z", "endTime": null,
    "mapName": "dm_atrium", "gameMode": "Deathmatch", "hostId": "clx1", "appId": 3, "serverId": 4821
  },
  "members": [
    { "userId": "clx1", "displayName": "Ashley", "gameName": "Ashley", "role": "HOST", "presence": "CONFIRMED",
      "score": 22, "kills": 18, "deaths": 11, "assist": 0, "joinedAt": "2026-07-29T20:00:00.000Z" }
  ]
}"""


func _test_backbone_shapes() -> void:
	_section("The backbone's party shapes, read as the site sends them")

	var parsed := DotParty.from_dict(JSON.parse_string(SITE_PARTY) as Dictionary)
	_check(parsed.ok, "the documented GET party/{id} answer parses")
	var p: DotParty = parsed.value
	_check(p.id == "4471" and p.max_users == 10 and p.server_id == 4821, "with its id, size and server")
	_check(p.is_live(), "a null endTime is a live party")
	_check(p.start_time == 1785355200, "an ISO time with milliseconds and a Z reads as the right second")
	var host := p.host()
	_check(host != null and host.display_name == "Ashley" and host.kills == 18, "the host is found, with their numbers")
	_check(host.server_uid() == "backbone:clx1", "and is recognised on a server by the uid dot-auth gives a session")

	# An id past 2^53 is exactly why the site sends a string.
	var big := DotParty.from_dict({"party": {"id": "9007199254740993"}, "members": []})
	_check(big.ok and (big.value as DotParty).id == "9007199254740993", "an id past 2^53 survives, because it is never a number")
	_check(not DotParty.from_dict({"party": {"id": "12a"}}).ok, "and an id that is not decimal is refused")
	_check(not DotParty.is_id("123456789012345678901"), "as is one longer than a 64-bit integer")

	var disagree := DotParty.from_dict({"id": "5", "hostId": "u2", "members": [
		{"userId": "u1", "role": "HOST"}, {"userId": "u2", "role": "MEMBER"},
	]})
	_check((disagree.value as DotParty).member("u2").role == DotPartyMember.Role.HOST, "the party's hostId wins when a row disagrees")
	_check(not DotPartyMember.from_dict({"displayName": "ghost"}).ok, "a member with no user id is refused rather than kept as a ghost")

	var back := p.copy()
	_check(back.member("clx1").joined_at == p.member("clx1").joined_at, "a party round-trips through its own dictionary")
	_check(str(DotPartyMember.format_time(1785355200))[10] == "T", "and writes times with the T, as RFC 3339 wants")


# --- 2 ----------------------------------------------------------------------

func _test_membership() -> void:
	_section("Membership follows the site's rules")

	var hub := _hub()
	var ada := hub.as_user("ada", "Ada")
	var bo := hub.as_user("bo", "Bo")
	var cy := hub.as_user("cy", "Cy")

	var made := ada.create({"name": "Friday", "maxUsers": 2})
	_check(made.ok, "a party is created")
	var pid := (made.value as DotParty).id
	_check(not ada.create({"name": "again"}).ok, "and its host cannot host a second")

	_check(bo.join(pid).ok, "someone joins")
	var full := cy.join(pid)
	_check(not full.ok and full.error.detail == "party.join.deny.full", "a full party refuses with the site's own reason key")

	var other: DotParty = cy.create({"name": "Other"}).value
	var moved := bo.join(other.id)
	_check(moved.ok and str((moved.value as Dictionary)["leftPartyId"]) == pid, "joining a second party leaves the first, and says which")
	_check(not (hub.fetch(pid).value as DotParty).has_member("bo"), "so nobody is in two live parties")

	var secret: DotParty = hub.as_user("dee").create({"type": "PRIVATE"}).value
	var shut := ada.join(secret.id)
	_check(not shut.ok and shut.error.detail == "party.join.deny.needInvite", "a private party refuses a stranger, with the site's key for it")
	var again_in := bo.join(other.id)
	_check(not again_in.ok and again_in.error.detail == "party.join.deny.alreadyIn", "joining a party you are in is refused as alreadyIn, as on the site")

	var pw := hub.as_user("eve").create({"type": "PUBLIC_PASSWORD", "password": "hunter22"})
	_check(pw.ok, "a password party is created")
	var pw_id := (pw.value as DotParty).id
	var wrong := hub.as_user("fay").join(pw_id, "wrong")
	_check(not wrong.ok and wrong.error.detail == "party.join.deny.wrongPassword", "the wrong password is refused")
	_check(hub.as_user("fay").join(pw_id, "hunter22").ok, "the right one is not")
	_check(not hub.as_user("gus").create({"type": "PUBLIC_PASSWORD", "password": "abc"}).ok, "a password under four characters is refused at creation")

	# The host leaving does not end it; the last one out does.
	var h: DotParty = hub.as_user("hal").create({}).value
	hub.as_user("ivy").join(h.id)
	hub.as_user("hal").leave(h.id)
	_check((hub.fetch(h.id).value as DotParty).is_live(), "the host leaving does not end a party")
	hub.as_user("ivy").leave(h.id)
	_check(not (hub.fetch(h.id).value as DotParty).is_live(), "the last member leaving does")

	# A host who stepped out of a full party always gets back in.
	var small: DotParty = hub.as_user("lia").create({"maxUsers": 2}).value
	hub.as_user("max").join(small.id)
	hub.as_user("lia").leave(small.id)
	hub.as_user("ned").join(small.id)
	_check(hub.as_user("lia").join(small.id).ok, "the host rejoins their own party even when it has filled up")
	_check((hub.fetch(small.id).value as DotParty).host().user_id == "lia", "as its host")

	# Silence is leaving.
	var q: DotParty = hub.as_user("jo").create({}).value
	hub.as_user("kim").join(q.id)
	_now[0] += 100
	hub.as_user("jo").heartbeat(q.id)
	_now[0] += 100
	hub.tick()
	var after: DotParty = hub.fetch(q.id).value
	_check(after.has_member("jo") and not after.has_member("kim"), "a member not heard from in 150 seconds is dropped, and one who heartbeat is not")


# --- 3 ----------------------------------------------------------------------

func _test_roles() -> void:
	_section("Who may do what to whom")

	var hub := _hub()
	var host := hub.as_user("h")
	var co := hub.as_user("c")
	var co2 := hub.as_user("c2")
	var m := hub.as_user("m")
	var pid: String = (host.create({}).value as DotParty).id
	co.join(pid)
	co2.join(pid)
	m.join(pid)

	_check(not m.kick(pid, "c").ok, "a member cannot kick")
	_check(host.set_role(pid, "c", DotPartyMember.Role.CO_HOST).ok, "the host makes a co-host")
	host.set_role(pid, "c2", DotPartyMember.Role.CO_HOST)
	_check(not co.kick(pid, "c2").ok, "a co-host cannot remove another co-host")
	_check(not co.kick(pid, "h").ok, "nor the host")
	_check(co.kick(pid, "m", true).ok, "but can ban a member")
	var back := m.join(pid)
	_check(not back.ok and back.error.detail == "party.join.deny.banned", "who then cannot come back")
	_check(not co.set_role(pid, "c2", DotPartyMember.Role.MEMBER).ok, "only the host changes roles")

	_check(host.transfer_host(pid, "c").ok, "the host hands the party over")
	var p: DotParty = hub.fetch(pid).value
	_check(p.host_id == "c" and p.host().user_id == "c", "and the new host is the host in both places")
	_check(p.member("h").role == DotPartyMember.Role.CO_HOST, "while the old one keeps the right to manage")


# --- 4 ----------------------------------------------------------------------

func _test_ready_round() -> void:
	_section("The ready round: everyone, or a share and a countdown")

	var hub := _hub()
	hub.add_server(7, "Arena EU", "dot://arena.example:27015")
	var a := hub.as_user("a")
	var b := hub.as_user("b")
	var c := hub.as_user("c")
	var d := hub.as_user("d")
	var pid: String = (a.create({"readyAutoPct": 75, "readyAutoSec": 10}).value as DotParty).id
	b.join(pid)
	c.join(pid)
	d.join(pid)

	_check(not b.start(pid, 7).ok, "only a manager opens the round")
	var opened := a.start(pid, 7)
	_check(opened.ok, "the host opens it on a server")
	var view: DotPartyReady = opened.value
	_check(view.stage == DotParty.Stage.READY and str(view.connect_info["url"]) == "dot://arena.example:27015", "and everybody is told where to connect")

	a.set_ready(pid)
	b.set_ready(pid)
	_check((a.ready_state(pid).value as DotPartyReady).countdown_sec == -1, "half ready arms nothing under a 75% threshold")
	c.set_ready(pid)
	var armed: DotPartyReady = a.ready_state(pid).value
	_check(armed.countdown_sec == 10, "three of four arms the ten-second countdown")
	_now[0] += 4
	c.set_ready(pid, false)
	_check((a.ready_state(pid).value as DotPartyReady).countdown_sec == -1, "and one un-readying disarms it")
	c.set_ready(pid)
	_now[0] += 6
	hub.tick()
	_check((hub.fetch(pid).value as DotParty).stage == DotParty.Stage.READY, "re-arming starts the count again rather than resuming it")
	_now[0] += 5
	hub.tick()
	_check((hub.fetch(pid).value as DotParty).stage == DotParty.Stage.PLAYING, "and when it runs out the round starts")

	var hub2 := _hub()
	hub2.add_server(1, "s", "dot://s")
	var x := hub2.as_user("x")
	var y := hub2.as_user("y")
	var p2: String = (x.create({}).value as DotParty).id
	y.join(p2)
	x.start(p2, 1)
	x.set_ready(p2)
	_check((hub2.fetch(p2).value as DotParty).stage == DotParty.Stage.READY, "with no threshold, one of two is not enough")
	y.set_ready(p2)
	_check((hub2.fetch(p2).value as DotParty).stage == DotParty.Stage.PLAYING, "and everybody ready starts it at once")
	_check(not hub2.as_user("z").join(p2).ok, "a stranger cannot join a public party whose game has started")


# --- 5 ----------------------------------------------------------------------

func _test_client() -> void:
	_section("The client turns snapshots into events and follows its party")

	var hub := _hub()
	hub.add_server(9, "Lobby", "dot://lobby.example:6090")
	var ada := DotPartyClient.new()
	ada.backend = hub.as_user("ada", "Ada")
	ada.user_id = "ada"
	add_child(ada)
	ada.set_process(false)

	var events: Array = []
	ada.joined_party.connect(func(p: DotParty) -> void: events.append("joined %s" % p.name))
	ada.member_joined.connect(func(m: DotPartyMember) -> void: events.append("+%s" % m.display_name))
	ada.member_left.connect(func(m: DotPartyMember, why: String) -> void: events.append("-%s %s" % [m.display_name, why]))
	ada.stage_changed.connect(func(_o: DotParty.Stage, n: DotParty.Stage) -> void: events.append("stage %s" % DotParty.STAGE_NAMES[n]))
	ada.left_party.connect(func(_id: String, why: String) -> void: events.append("left %s" % why))
	var connects: Array = []
	ada.connect_requested.connect(func(url: String, _i: Dictionary) -> void: connects.append(url))
	var dialled: Array = []
	ada.connect_fn = func(url: String, _i: Dictionary) -> DotResult:
		dialled.append(url)
		return DotResult.success(null)

	var made := await ada.create({"name": "Night"})
	_check(made.ok and ada.party != null, "creating through the client leaves it in the party")
	_check(events.has("joined Night"), "and says so")

	var bo := hub.as_user("bo", "Bo")
	var cy := hub.as_user("cy", "Cy")
	bo.join(ada.party.id)
	cy.join(ada.party.id)
	await ada.refresh()
	_check(events.has("+Bo") and events.has("+Cy"), "people joining between polls are announced")
	_check(events.find("+Bo") < events.find("+Cy"), "in the order they joined")

	await ada.kick("cy")
	_check(events.has("-Cy kicked"), "a kick is reported as a kick, not a leave")

	await ada.start(9)
	_check(events.has("stage READY"), "opening the round is a stage change")
	_check(connects.size() == 1 and connects[0] == "dot://lobby.example:6090", "and a request to connect, once")
	await get_tree().process_frame
	_check(dialled.size() == 1, "which the client followed by itself")
	_check(ada.party.member("ada").has_connected(), "and then told the backbone it had arrived")
	await ada.refresh()
	await ada.refresh()
	_check(connects.size() == 1, "polling during the round does not connect again")

	hub.cancel_ready("ada", ada.party.id)
	await ada.refresh()
	await ada.start(9)
	_check(connects.size() == 2, "a second round on the same server is followed again")

	# Being kicked yourself.
	var bo_client := DotPartyClient.new()
	bo_client.backend = bo
	bo_client.user_id = "bo"
	add_child(bo_client)
	bo_client.set_process(false)
	await bo_client.refresh()
	var bo_left: Array = []
	bo_client.left_party.connect(func(_id: String, why: String) -> void: bo_left.append(why))
	hub.kick("ada", ada.party.id, "bo", false)
	await bo_client.refresh()
	_check(bo_left == ["kicked"] and bo_client.party == null, "a player who is kicked is told they were kicked")

	_check(ada.poll_interval() == ada.config.ready_poll_sec, "a client polls fast during a ready round")
	var failed := await ada.join("not-an-id")
	_check(not failed.ok, "a malformed party id is refused before anything is asked")
	ada.queue_free()
	bo_client.queue_free()


# --- 6 ----------------------------------------------------------------------

func _test_policy() -> void:
	_section("Booking terms are the site's, including the window that crosses midnight")

	var pol := DotPartyReservePolicy.new()
	pol.enabled = true
	pol.from_minute = 22 * 60
	pol.to_minute = 2 * 60
	pol.days = [5]  # Friday
	# 2026-09-25 is a Friday. 23:00 Friday is in; 01:00 Saturday is in, because the
	# window opened on Friday; 01:00 Friday is NOT, because Thursday is not a day.
	var fri_2300 := _utc(2026, 9, 25, 23, 0)
	var sat_0100 := _utc(2026, 9, 26, 1, 0)
	var fri_0100 := _utc(2026, 9, 25, 1, 0)
	_check(pol.window_open(fri_2300), "23:00 Friday is inside a Friday 22:00-02:00 window")
	_check(pol.window_open(sat_0100), "01:00 Saturday is too, because the window opened on Friday")
	_check(not pol.window_open(fri_0100), "01:00 Friday is not: Thursday's window was never open")
	_check(pol.window_closes(fri_2300) == _utc(2026, 9, 26, 2, 0), "from 23:00 the window closes at 02:00 the next day")
	_check(pol.window_closes(sat_0100) == _utc(2026, 9, 26, 2, 0), "and from 01:00, at 02:00 the same day")
	_check(pol.next_open(fri_0100) == _utc(2026, 9, 25, 22, 0), "the next opening is found a day at a time")

	var granted := pol.grant(_utc(2026, 9, 26, 1, 30), 90, false, pol.offer(_utc(2026, 9, 26, 1, 30), "1", 0))
	_check(granted.ok and int((granted.value as Dictionary)["minutes"]) == 30, "ninety minutes asked half an hour before close is thirty granted")
	var late := pol.grant(_utc(2026, 9, 26, 1, 57), 60, false, pol.offer(_utc(2026, 9, 26, 1, 57), "1", 0))
	_check(not late.ok and late.error.detail == "party.reserve.deny.window", "three minutes is refused rather than granted")
	_check(not pol.grant(fri_2300, 60, true, pol.offer(fri_2300, "1", 0)).ok, "a private booking on a public-only server is refused, not coerced")

	var open := DotPartyReservePolicy.new()
	open.enabled = true
	var t := _utc(2026, 9, 23, 12, 0)
	_check(str(DotPartyReservePolicy.new().offer(t, "1", 0)["deny"]) == "off", "a server that has not opted in is off")
	_check(str(open.offer(t, "1", 3)["deny"]) == "populated", "an empty-only server with people on it is populated")
	var held := DotPartyReservation.new()
	held.party_id = "2"
	held.status = DotPartyReservation.Status.ACTIVE
	held.ends_at = t + 600
	_check(str(open.offer(t, "1", 0, held)["deny"]) == "taken", "a server another party holds is taken")
	_check(str(open.offer(t, "2", 0, held)["deny"]) == "already", "and one this party holds is already")
	var last := DotPartyReservation.new()
	last.party_id = "1"
	last.status = DotPartyReservation.Status.ENDED
	last.ends_at = t - 60
	var cool := open.offer(t, "1", 0, null, last)
	_check(str(cool["deny"]) == "cooldown" and int(cool["freeAt"]) == t - 60 + 15 * 60, "booking again straight after is a cooldown, with when it lifts")
	open.max_minutes = 600
	_check(open.ceiling_minutes() == 180, "an owner cannot offer more than the deployment allows")


# --- 7 ----------------------------------------------------------------------

class BanList:
	extends RefCounted
	var banned: Dictionary = {}

	func check_admission(uid: String, _address: String) -> DotResult:
		if banned.has(uid):
			return DotResult.fail(DotError.CODE_FORBIDDEN, "banned")
		return DotResult.success(true)


func _test_reservations() -> void:
	_section("A booked server admits its party, and holds seats while it arrives")

	var bans := BanList.new()
	bans.banned["backbone:villain"] = true
	DotRegistry.register(&"dot_ban_source", bans)

	var seats: Array[Vector2i] = [Vector2i(0, 10)]
	var gate := DotPartyReservations.new()
	gate.now_fn = func() -> int: return _now[0]
	gate.seats_fn = func() -> Vector2i: return seats[0]
	gate.bypass_fn = func(uid: String) -> bool: return uid == "backbone:owner"
	var pol := DotPartyReservePolicy.new()
	pol.enabled = true
	pol.lobbies = DotPartyReservePolicy.Lobbies.PUBLIC_AND_PRIVATE
	gate.policy = pol
	add_child(gate)
	gate.set_process(false)

	_check(DotRegistry.get_service(&"dot_ban_source") == gate, "it takes the admission seam")
	_check(gate.previous_source == bans, "and keeps the ban list that held it")
	_check(not gate.check_admission("backbone:villain", "1.2.3.4").ok, "so a banned player is still refused with no booking in force")

	var party := _party("p1", ["a", "b", "c", "villain"])
	var booked := gate.book(party, 120, true)
	_check(booked.ok and gate.current.is_private, "a private booking is made under the server's own terms")
	_check(gate.check_admission("backbone:a", "1.1.1.1").ok, "a member is admitted")
	var stranger := gate.check_admission("backbone:zed", "9.9.9.9")
	_check(not stranger.ok and stranger.error.detail == "party.reserve.private", "a stranger is not")
	_check(gate.check_admission("", "9.9.9.9").ok, "the address-only pass is not judged, since a booking is about people")
	_check(gate.check_admission("backbone:owner", "9.9.9.9").ok, "the owner is not locked out of their own server")
	_check(not gate.check_admission("backbone:villain", "1.2.3.4").ok, "and a banned member of the party is still banned")

	gate.release()
	var pub := gate.book(_party("p2", ["a", "b", "c"]), 60, false)
	_check(pub.ok and not gate.current.is_private, "a public booking")
	seats[0] = Vector2i(6, 10)
	_check(gate.seats_owed(_now[0]) == 3, "holds a seat for each member not yet here")
	_check(gate.check_admission("backbone:zed", "").ok, "a stranger may take one of four free seats while three are held")
	seats[0] = Vector2i(7, 10)
	_check(not gate.check_admission("backbone:zed", "").ok, "but not one of the last three")
	_check(gate.check_admission("backbone:a", "").ok, "which a member may")
	gate.note_arrival("backbone:a")
	gate.note_arrival("backbone:b")
	_check(gate.seats_owed(_now[0]) == 1, "arrivals release their held seat")
	_check(gate.check_admission("backbone:zed", "").ok, "so a stranger fits again")
	_now[0] += int(gate.config.seat_hold_sec) + 1
	seats[0] = Vector2i(9, 10)
	_check(gate.seats_owed(_now[0]) == 0, "and once the hold window is over, nothing is held for somebody who never came")

	var ended: Array = []
	var warned: Array = []
	gate.reservation_ended.connect(func(_r: DotPartyReservation, why: String) -> void: ended.append(why))
	gate.reservation_ending.connect(func(_r: DotPartyReservation, left: int) -> void: warned.append(left))
	gate.note_departure("backbone:a")
	gate.note_departure("backbone:b")
	_now[0] += int(gate.config.release_when_empty_sec) + 1
	gate.tick()
	_check(ended == ["empty"], "a booking its party has abandoned is released early")

	var busy := gate.book(_party("p3", ["a"]), 30, false)
	_check(not busy.ok and busy.error.detail == "party.reserve.deny.populated", "an empty-only server with nine people on it will not be booked here either")
	seats[0] = Vector2i(0, 10)
	_check(gate.book(_party("p3", ["a"]), 30, false).ok, "and will once they have gone")
	_now[0] += 30 * 60 - 200
	gate.tick()
	_check(warned.size() == 1 and int(warned[0]) <= 300, "the server is warned before a booking ends")
	_now[0] += 201
	gate.tick()
	_check(ended.back() == "expired" and gate.current == null, "and it expires on time")

	# A website booking, through a hub standing in for the backbone.
	var hub := _hub()
	var hub_pol := DotPartyReservePolicy.new()
	hub_pol.enabled = true
	hub_pol.lobbies = DotPartyReservePolicy.Lobbies.PRIVATE_ONLY
	hub.add_server(42, "Scrim", "dot://scrim", hub_pol)
	var lead := hub.as_user("lead")
	var sp: DotParty = lead.create({}).value
	hub.as_user("mate").join(sp.id)
	var r := lead.reserve(sp.id, 42, 60, true)
	_check(r.ok, "a party books a server through its backend")
	gate.server_id = 42
	gate.use_hub(hub)
	var synced := await gate.sync()
	_check(synced.ok and gate.current != null and gate.party.has_member("mate"), "the game server learns the booking and who it is for")
	_check(not gate.check_admission("backbone:zed", "").ok, "and keeps the stranger out")

	# An outage must not open a private server.
	gate.fetch_fn = func() -> DotResult: return DotResult.fail(DotError.CODE_NETWORK, "down")
	await gate.sync()
	_check(gate.current != null, "a backbone that cannot be reached leaves the booking in force")

	var parsed := DotPartyReservations.parse_backbone({"ok": true, "reservation": {
		"id": "88", "partyId": "4471", "serverId": 4821, "status": "ACTIVE", "private": true,
		"startsAt": "2026-09-23T20:00:00.000Z", "endsAt": "2026-09-23T22:00:00.000Z",
	}, "party": {"id": "4471"}, "members": [{"userId": "clx1", "role": "HOST"}]})
	_check(parsed.ok and ((parsed.value as Dictionary)["party"] as DotParty).has_member("clx1"), "the proposed backbone answer parses")
	_check((DotPartyReservations.parse_backbone({"ok": true, "reservation": null}).value) == null, "and 'not booked' is null, not an error")

	gate.queue_free()
	await get_tree().process_frame
	_check(DotRegistry.get_service(&"dot_ban_source") == bans, "removing it hands the seam back to the ban list")
	DotRegistry.unregister_instance(&"dot_ban_source", bans)


# --- 8 ----------------------------------------------------------------------

class FakeAuthClient:
	extends RefCounted
	var calls: Array = []

	func get_app(path: String, query: Dictionary = {}) -> DotResult:
		calls.append(["GET", path, query])
		return DotResult.success(null)

	func post_app(path: String, body: Dictionary) -> DotResult:
		calls.append(["POST", path, body])
		# What dot-auth hands back for a refusal: the site's code already in the detail.
		return DotResult.failure(DotError.make(DotError.CODE_CONFLICT, "This party is full.", "party.join.deny.full"))


class FakeIntegration:
	extends RefCounted
	var calls: Array = []
	var parties: Dictionary = {}
	var status: int = 200

	func post_integration(path: String, body: Dictionary) -> DotResult:
		calls.append([path, body])
		if status != 200:
			return DotResult.failure(DotError.from_http(status, "{\"error\":\"nope\"}"))
		if path == "party/create":
			parties["900"] = {"party": {"id": "900", "name": body["name"]}, "members": []}
			return DotResult.success({"ok": true, "partyId": "900", "url": "/parties/900"})
		return DotResult.success({"ok": true})

	func get_integration(path: String, _query: Dictionary = {}) -> DotResult:
		calls.append([path, {}])
		var id := path.get_slice("/", 1)
		if not parties.has(id):
			return DotResult.failure(DotError.from_http(404, "{\"error\":\"Party not found.\"}"))
		return DotResult.success(parties[id])


func _test_server_reporting() -> void:
	_section("The game server tracks parties and reports them the site's way")

	var fake := FakeIntegration.new()
	fake.parties["4471"] = JSON.parse_string(SITE_PARTY)
	var srv := DotPartyServer.new()
	srv.client = fake
	var here: Array = [
		{"name": "Ashley", "uid": "backbone:clx1", "score": 5},
		{"name": "Guest", "uid": "guest:77"},
	]
	srv.players_fn = func() -> Array: return here
	add_child(srv)
	srv.set_process(false)

	var claimed := await srv.claim("backbone:clx1", "4471")
	_check(claimed.ok and srv.parties.has("4471"), "a member's claim is checked against the roster and the party tracked")
	var lie := await srv.claim("backbone:mallory", "4471")
	_check(not lie.ok and lie.error.code == DotError.CODE_FORBIDDEN, "a claim to a party somebody is not in is refused")
	_check(srv.party_of("backbone:clx1") == "4471" and srv.party_of("guest:77") == "", "the server knows who is in which party")

	fake.calls.clear()
	await srv.report_state("dm_atrium", "deathmatch")
	var state: Dictionary = fake.calls[0][1]
	_check(str(fake.calls[0][0]) == "party/state" and (state["players"] as Array).size() == 2, "the state report carries everybody on the server")
	var row: Dictionary = (state["players"] as Array)[0]
	_check(row["name"] == "Ashley" and not row.has("uid"), "by name, and never with the session uid")
	_check(str(state["mapName"]) == "dm_atrium", "with the map")

	fake.calls.clear()
	await srv.player_joined({"name": "Ashley", "uid": "backbone:clx1"})
	_check(fake.calls.size() == 1 and fake.calls[0][1]["partyId"] == "4471", "a member's join goes to their party")
	fake.calls.clear()
	await srv.player_joined({"name": "Stranger", "uid": "backbone:nobody"})
	_check(fake.calls.is_empty(), "a signed-in non-member's join goes nowhere")

	fake.calls.clear()
	await srv.match_ended([{"name": "Ashley", "uid": "backbone:clx1", "kills": 3, "place": 1}])
	var end_body: Dictionary = fake.calls[0][1]
	_check(end_body["event"] == "end" and ((end_body["players"] as Array)[0] as Dictionary)["place"] == 1, "a finished round is filed with places")

	var groups := srv.groups(PackedStringArray(["backbone:clx1", "guest:77"]))
	_check(groups.size() == 2, "players are grouped by party for a balancer that keeps parties whole")

	_check(not (await srv.create_party("x", 8, "PRIVATE")).ok, "a server cannot create a private party")
	var made := await srv.create_party("Everyone here", 12)
	_check(made.ok and srv.parties.has("900"), "it can create a public one, and tracks it")

	fake.status = 403
	var denied := await srv.report_state()
	_check(not denied.ok and denied.error.message.contains("party scopes"), "a 403 names the missing scope")
	srv.queue_free()


# --- 9 ----------------------------------------------------------------------

func _test_app_backend() -> void:
	_section("The player's backend speaks the app API's envelope")

	var sent: Array = []
	var answers: Array = []
	var app := DotPartyBackendApp.new("https://tmc.example/api/app/v1")
	app.request_fn = func(method: String, path: String, body: Dictionary) -> DotResult:
		sent.append([method, path, body])
		return answers.pop_front()

	answers.append(DotResult.success({"ok": true, "data": null}))
	var none := await app.mine()
	_check(none.ok and none.value == null, "not being in a party is a success with nothing in it")

	answers.append(DotResult.success({"ok": true, "data": JSON.parse_string(SITE_PARTY)}))
	var mine := await app.mine()
	_check(mine.ok and (mine.value as DotParty).id == "4471", "a party comes back as a party")

	answers.append(DotResult.success({"ok": false, "code": "party.join.deny.full", "message": "That party is full."}))
	var full := await app.join("4471")
	_check(not full.ok and full.error.detail == "party.join.deny.full", "a refusal carries the site's key where every backend puts it")
	_check(sent[2][1] == "party/join" and sent[2][2]["id"] == "4471", "and the request uses the site's own field names")

	var err := DotError.from_http(429, "{\"ok\":false,\"code\":\"rate_limited\",\"message\":\"Slow down.\",\"retryAfter\":12}")
	answers.append(DotResult.failure(err))
	var slow := await app.set_ready("4471")
	_check(not slow.ok and slow.error.retry_after == 12.0 and slow.error.code == DotError.CODE_RATE_LIMITED, "a 429 keeps its retry-after")

	answers.append(DotResult.failure(DotError.from_http(404, "")))
	var missing := await app.heartbeat("4471")
	_check(not missing.ok and missing.error.message.contains("no app party routes yet"), "a 404 says the site has not grown the routes yet")
	_check(missing.error.detail == "", "and leaves the refusal-key field empty, since there is no key to render")

	_check(not (await app.fetch("x1")).ok, "a malformed id is refused before a request is made")

	var via_auth := DotPartyBackendApp.new()
	var auth := FakeAuthClient.new()
	via_auth.client = auth
	var offer := await via_auth.reservation_offer("4471", 12)
	_check(offer.ok and auth.calls[0][0] == "GET" and (auth.calls[0][2] as Dictionary)["serverId"] == 12, "through dot-auth's client, a query goes as a query")
	var refused := await via_auth.join("4471")
	_check(not refused.ok and refused.error.detail == "party.join.deny.full", "and a refusal keeps the site's key")
	_check(not (await app.invite("4471", PackedStringArray(range(26).map(func(i: int) -> String: return str(i))))).ok, "and so are twenty-six invites at once")

	# The site's snapshot carries no `connect`; only its ready view does. A client that
	# read the address off `mine` alone was never sent anywhere against the real site.
	var ready_party := {"id": "4471", "stage": "READY", "endTime": null, "members": [
		{"userId": "u1", "role": "HOST", "state": "JOINED"},
	]}
	var ready_view := {"total": 1, "ready": 1, "connect": {"serverId": 12, "serverName": "Lobby", "url": "dot://lobby.example:6090"}}
	var site := DotPartyBackendApp.new("https://tmc.example/api/app/v1")
	var asked: Array = []
	site.request_fn = func(method: String, path: String, _body: Dictionary) -> DotResult:
		asked.append("%s %s" % [method, path])
		if path == "party/mine":
			return DotResult.success({"ok": true, "data": ready_party.duplicate(true)})
		if path == "party/4471/ready":
			return DotResult.success({"ok": true, "data": ready_view})
		return DotResult.success({"ok": true, "data": null})
	var follower := DotPartyClient.new()
	follower.backend = site
	follower.user_id = "u1"
	follower.follow = false
	add_child(follower)
	follower.set_process(false)
	var sent_to: Array = []
	follower.connect_requested.connect(func(url: String, _i: Dictionary) -> void: sent_to.append(url))
	await follower.refresh()
	_check(sent_to == ["dot://lobby.example:6090"], "against the site, a ready round's address comes from its ready view")
	_check(asked.has("GET party/4471/ready"), "which is asked only because the snapshot did not say")
	follower.queue_free()


# --- helpers ------------------------------------------------------------------

func _hub() -> DotPartyLocalHub:
	var hub := DotPartyLocalHub.new()
	hub.now_fn = func() -> int: return _now[0]
	return hub


func _party(id_seed: String, users: Array) -> DotParty:
	var rows := []
	for u in users:
		rows.append({"userId": str(u), "displayName": str(u)})
	var n := 100 + id_seed.hash() % 900
	return DotParty.from_dict({"id": str(absi(n)), "members": rows}).value


func _utc(y: int, mo: int, d: int, h: int, mi: int) -> int:
	return int(Time.get_unix_time_from_datetime_dict({"year": y, "month": mo, "day": d, "hour": h, "minute": mi, "second": 0}))


func _section(title: String) -> void:
	_section_count += 1
	_line("-- %d. %s" % [_section_count, title])


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
		_line("   ok    %s" % what)
	else:
		_failed += 1
		_line("   FAIL  %s" % what)


func _line(s: String) -> void:
	print(s)

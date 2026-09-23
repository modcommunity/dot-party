@tool
class_name DotPartyReservePolicy
extends Resource

## A server owner's terms for letting a party book their server.
##
## [b]A port of website-city's rules, not a second design.[/b] The fields are the
## [code]partyReserve*[/code] columns on the site's [code]Server[/code], and [method offer],
## [method window_open] and [method window_closes] are [code]ServerReservationOffer[/code],
## [code]ReserveWindowOpen[/code] and [code]ReserveWindowCloses[/code] line for line — the
## wrapped 22:00→02:00 window included. It is duplicated rather than fetched for the
## reason dot-stats duplicates its merge rule: a LAN server with no backbone still has to
## answer "can this party book me", and two implementations that disagree about a booking
## window is a party turned away at the door of a server the site said was theirs. The
## suite checks the same cases the site's own tests do.
##
## Every time is UTC. A server owner in one zone and a party in another reading a window in
## local time is how "the server is bookable from eight" means two different hours.

enum Lobbies { PUBLIC_ONLY, PUBLIC_AND_PRIVATE, PRIVATE_ONLY }

## The shortest booking worth granting. Asking right at the end of a window can clamp a
## booking down to a few minutes, and refusing is kinder than granting four.
const MIN_MINUTES := 5
const DAY_MINUTES := 1440

## Whether parties may book this server at all.
@export var enabled: bool = false

## Which booking shapes are offered.
@export var lobbies: Lobbies = Lobbies.PUBLIC_ONLY

## Only when nobody (human) is on it. On by default, as on the site: booking a server out
## from under the people already playing on it is not something an owner opts into by
## accident.
@export var empty_only: bool = true

## The owner's ceiling in minutes. 0 means the deployment's ([member site_max_minutes]).
@export_range(0, 1440, 5) var max_minutes: int = 0

## The deployment's ceiling. The site's default is three hours.
@export_range(15, 1440, 5) var site_max_minutes: int = 180

## Whether a request is granted at once or waits for the owner.
@export var auto_approve: bool = true

## Minutes after a booking ends before the same party may book again.
@export_range(0, 1440, 1) var cooldown_minutes: int = 15

## UTC days a booking may be made, 0 = Sunday. Empty is every day.
@export var days: Array[int] = []

## UTC minutes of the day the window opens and closes. Equal means all day; from after to
## is a window that crosses midnight.
@export_range(0, 1439, 1) var from_minute: int = 0
@export_range(0, 1439, 1) var to_minute: int = 0


func allows_public() -> bool:
	return lobbies != Lobbies.PRIVATE_ONLY


func allows_private() -> bool:
	return lobbies != Lobbies.PUBLIC_ONLY


## Whether [param at] (Unix seconds) is inside the booking window.
func window_open(at: int) -> bool:
	var weekday := _weekday(at)
	if from_minute == to_minute:
		return _day_ok(weekday)
	var minute := _minute_of_day(at)
	if from_minute < to_minute:
		return _day_ok(weekday) and minute >= from_minute and minute < to_minute
	# Wrapped: either late on today, or early on a day whose window opened yesterday.
	if minute >= from_minute:
		return _day_ok(weekday)
	return minute < to_minute and _day_ok(weekday - 1)


## When the window containing [param at] closes, or 0 when it is all day.
func window_closes(at: int) -> int:
	if from_minute == to_minute:
		return 0
	var minute := _minute_of_day(at)
	var midnight := at - (at % 86400)
	var add_days := 1 if from_minute > to_minute and minute >= from_minute else 0
	return midnight + add_days * 86400 + to_minute * 60


## When the window next opens after [param from], or 0 for never. Searched a day at a time
## for the site's reason: the wrapped case makes the closed form different on each side of
## midnight, and eight iterations of a pure function are harder to get wrong.
func next_open(from: int) -> int:
	var midnight := from - (from % 86400)
	for i in range(8):
		var candidate := midnight + i * 86400 + from_minute * 60
		if candidate <= from:
			continue
		if window_open(candidate):
			return candidate
	return 0


## The deployment's ceiling, then the owner's own, never under five minutes.
func ceiling_minutes() -> int:
	var owner := max_minutes if max_minutes > 0 else site_max_minutes
	return maxi(MIN_MINUTES, mini(mini(site_max_minutes, owner), DAY_MINUTES))


## What this server can offer [param party_id] at [param now].
##
## [param humans] is who is playing on it now, bots excluded — a bot slot or a relay is not
## a person whose game a booking would interrupt. [param held] is the booking the server
## has now (PENDING or ACTIVE and not yet over), or null. [param last_for_party] is the most
## recent ACTIVE or ENDED booking by this same party, or null, for the cooldown.
##
## Value: [code]{available, deny, allowPublic, allowPrivate, maxMinutes, opensAt, freeAt}[/code],
## with [code]deny[/code] one of the site's closed set: [code]off window taken already
## offline populated cooldown[/code].
func offer(now: int, party_id: String, humans: int, held: DotPartyReservation = null,
		last_for_party: DotPartyReservation = null, online: bool = true) -> Dictionary:
	var base := {
		"available": true,
		"deny": "",
		"allowPublic": allows_public(),
		"allowPrivate": allows_private(),
		"maxMinutes": 0,
		"opensAt": 0,
		"freeAt": 0,
	}
	if not enabled:
		return _deny(base, "off")
	if not window_open(now):
		var d := _deny(base, "window")
		d["opensAt"] = next_open(now)
		return d

	var cap := ceiling_minutes()
	base["maxMinutes"] = cap

	if held != null and held.ends_at > now and (held.status == DotPartyReservation.Status.PENDING \
			or held.status == DotPartyReservation.Status.ACTIVE):
		var d := _deny(base, "already" if held.party_id == party_id else "taken")
		d["maxMinutes"] = cap
		d["freeAt"] = held.ends_at
		return d

	if not online:
		var d := _deny(base, "offline")
		d["maxMinutes"] = cap
		return d

	if empty_only and humans > 0:
		var d := _deny(base, "populated")
		d["maxMinutes"] = cap
		return d

	if party_id != "" and cooldown_minutes > 0 and last_for_party != null \
			and last_for_party.party_id == party_id \
			and (last_for_party.status == DotPartyReservation.Status.ACTIVE \
				or last_for_party.status == DotPartyReservation.Status.ENDED) \
			and last_for_party.ends_at > now - cooldown_minutes * 60:
		var d := _deny(base, "cooldown")
		d["maxMinutes"] = cap
		d["freeAt"] = last_for_party.ends_at + cooldown_minutes * 60
		return d

	return base


## The booking actually granted for a request of [param minutes], or a refusal.
##
## [b]Clamped, not refused[/b]: somebody asking for ninety minutes twenty minutes before the
## window shuts gets twenty, and is told so. A lobby shape the server does not offer IS
## refused rather than coerced — "private" means nobody else gets in, and quietly handing a
## host a public booking is something they would find out about from a stranger.
##
## Value: [code]{starts_at, ends_at, minutes, private}[/code]; the refusal's detail is the
## site's [code]party.reserve.deny.*[/code] key.
func grant(now: int, minutes: int, want_private: bool, offer_value: Dictionary) -> DotResult:
	if not bool(offer_value.get("available", false)):
		return _refuse(str(offer_value.get("deny", "off")))
	if want_private and not allows_private():
		return _refuse("shape")
	if not want_private and not allows_public():
		return _refuse("shape")

	var asked := mini(maxi(minutes, 0), int(offer_value.get("maxMinutes", ceiling_minutes())))
	var ends := now + asked * 60
	var closes := window_closes(now)
	if closes > 0 and closes < ends:
		ends = closes
	var granted := int(round(float(ends - now) / 60.0))
	if granted < MIN_MINUTES:
		return _refuse("window")
	return DotResult.success({"starts_at": now, "ends_at": ends, "minutes": granted, "private": want_private})


func validate() -> DotResult:
	for d in days:
		if d < 0 or d > 6:
			return DotResult.fail(DotError.CODE_INVALID, "a booking day is 0 (Sunday) to 6", str(d))
	return DotResult.success(null)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	if not enabled:
		out.append("reservations: off")
		return out
	out.append("reservations: %s, up to %d min, %s, cooldown %d min" % [
		["public only", "public or private", "private only"][lobbies],
		ceiling_minutes(),
		"auto-approved" if auto_approve else "approved by hand",
		cooldown_minutes,
	])
	var when := "all day" if from_minute == to_minute else "%02d:%02d-%02d:%02d UTC" % [
		floori(from_minute / 60.0), from_minute % 60, floori(to_minute / 60.0), to_minute % 60,
	]
	out.append("  %s, %s%s" % [when, "every day" if days.is_empty() else "days %s" % str(days),
		", only when empty" if empty_only else ""])
	return out


func _day_ok(weekday: int) -> bool:
	return days.is_empty() or days.has(((weekday % 7) + 7) % 7)


static func _weekday(at: int) -> int:
	# 1970-01-01 was a Thursday, day 4.
	return int(floor(float(at) / 86400.0) + 4) % 7


static func _minute_of_day(at: int) -> int:
	return floori((at % 86400) / 60.0)


static func _deny(base: Dictionary, reason: String) -> Dictionary:
	var d := base.duplicate()
	d["available"] = false
	d["deny"] = reason
	d["maxMinutes"] = 0
	return d


static func _refuse(reason: String) -> DotResult:
	var messages := {
		"off": "This server is not taking party bookings.",
		"window": "This server is outside its booking hours.",
		"taken": "This server is already booked by another party.",
		"already": "Your party already has this server booked.",
		"offline": "This server is offline.",
		"populated": "This server only takes bookings when it is empty.",
		"cooldown": "Your party booked this server recently. Try again shortly.",
		"shape": "This server does not offer that kind of booking.",
	}
	return DotResult.fail(
		DotError.CODE_CONFLICT if reason != "shape" else DotError.CODE_INVALID,
		str(messages.get(reason, "This server cannot be booked right now.")),
		"party.reserve.deny.%s" % reason
	)

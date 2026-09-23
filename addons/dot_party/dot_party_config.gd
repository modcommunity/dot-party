@tool
class_name DotPartyConfig
extends DotConfig

## Timings for both halves of a party: the player's client and the game server.
##
## Most of these are the backbone's own numbers, mirrored. A client that heartbeats less
## often than the site expects is a client whose player is removed from their own party,
## and a server that reports its roster less often than the site reconciles is a party
## whose play time is recorded in lumps.

@export_group("Client")

## Seconds between polls in a lobby. The site's own pages use half the heartbeat.
@export_range(1.0, 120.0, 0.5) var poll_sec: float = 22.5

## Seconds between polls during a ready round, when everybody is about to be told where to go.
@export_range(0.5, 30.0, 0.5) var ready_poll_sec: float = 1.5

## Seconds between heartbeats. The site drops a member after 150 silent seconds, so this
## must stay well under that; 45 is the site's own figure.
@export_range(5.0, 120.0, 1.0) var heartbeat_sec: float = 45.0

@export_group("Server")

## Seconds between full roster reports to the backbone ([code]party/state[/code]). The
## site asks for 10 to 30.
@export_range(5.0, 120.0, 1.0) var state_report_sec: float = 15.0

## Seconds between re-reading the rosters of the parties on this server.
@export_range(5.0, 600.0, 5.0) var roster_refresh_sec: float = 60.0

## Seconds between asking the backbone whether this server is booked.
@export_range(5.0, 600.0, 5.0) var reservation_sync_sec: float = 30.0

## Seconds after a booking starts during which seats are held for party members who have
## not arrived yet. The join-together window: long enough for eight people to load a map,
## short enough that one who never comes does not keep a seat all evening.
@export_range(0.0, 1800.0, 5.0) var seat_hold_sec: float = 180.0

## Seconds before a booking ends to warn the people on the server.
@export_range(0.0, 3600.0, 10.0) var reservation_warn_sec: float = 300.0

## Seconds a booked server may sit with none of its party on it before the booking is
## released early. 0 never releases early.
@export_range(0.0, 7200.0, 10.0) var release_when_empty_sec: float = 600.0


func env_prefix() -> String:
	return "DOT_PARTY_"


func cli_prefix() -> String:
	return "--party-"


func validate() -> DotResult:
	if heartbeat_sec >= 150.0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"a heartbeat of %.0fs is at or past the backbone's 150s staleness limit" % heartbeat_sec,
			"every member would be dropped from their own party"
		)
	if ready_poll_sec > poll_sec:
		return DotResult.fail(DotError.CODE_INVALID, "the ready round polls slower than the lobby")
	return DotResult.success(null)


func describe_lines(_redact_sensitive: bool = true) -> PackedStringArray:
	var out := PackedStringArray()
	out.append("party: poll %.1fs (%.1fs in a ready round), heartbeat %.0fs" % [poll_sec, ready_poll_sec, heartbeat_sec])
	out.append("  server: roster report %.0fs, booking sync %.0fs, seats held %.0fs" % [
		state_report_sec, reservation_sync_sec, seat_hold_sec,
	])
	return out

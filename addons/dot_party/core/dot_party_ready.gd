class_name DotPartyReady
extends RefCounted

## The ready round: who is ready, who has connected, and whether it is about to start.
##
## The backbone's [code]PartyReadyView[/code], which is what a ready screen draws. The
## round starts when everybody is ready, or — if the party set an automatic threshold — a
## countdown is armed once that share is ready and the round starts when it runs out. A
## countdown that drops back below the threshold is disarmed, so one person un-readying
## is not a start nobody wanted.

var stage: DotParty.Stage = DotParty.Stage.LOBBY
var total: int = 0
var ready: int = 0
## Percent ready, 0-100.
var pct: int = 0
## The automatic-start threshold in percent (0 is off) and its countdown in seconds.
var auto_pct: int = 0
var auto_sec: int = 30
## Seconds until an armed countdown starts the round, or -1 when none is armed.
var countdown_sec: int = -1
## Where to connect: [code]{serverId, serverName, url}[/code], or empty.
var connect_info: Dictionary = {}
var started: bool = false
## This player: [code]{isMember, ready, connected, canManage}[/code].
var me: Dictionary = {}


static func from_dict(d: Dictionary) -> DotPartyReady:
	var r := DotPartyReady.new()
	r.stage = DotParty.parse_stage(str(d.get("stage", "LOBBY")))
	r.total = int(d.get("total", 0))
	r.ready = int(d.get("ready", 0))
	r.pct = int(d.get("pct", 0))
	r.auto_pct = int(d.get("autoPct", 0))
	r.auto_sec = int(d.get("autoSec", 30))
	r.countdown_sec = int(d.get("countdownSec", -1)) if d.get("countdownSec") != null else -1
	if d.get("connect") is Dictionary:
		r.connect_info = (d["connect"] as Dictionary).duplicate()
	r.started = bool(d.get("started", false))
	if d.get("me") is Dictionary:
		r.me = (d["me"] as Dictionary).duplicate()
	return r


func to_dict() -> Dictionary:
	return {
		"stage": DotParty.STAGE_NAMES[stage],
		"total": total,
		"ready": ready,
		"pct": pct,
		"autoPct": auto_pct,
		"autoSec": auto_sec,
		"countdownSec": countdown_sec if countdown_sec >= 0 else null,
		"connect": connect_info if not connect_info.is_empty() else null,
		"started": started,
		"me": me,
	}


## The site's rule, which the local backend shares: at least one ready, and the share
## ready at or over the threshold.
static func threshold_met(auto_pct_value: int, ready_count: int, total_count: int) -> bool:
	if auto_pct_value <= 0 or total_count < 1 or ready_count < 1:
		return false
	return float(ready_count) / float(total_count) * 100.0 >= float(mini(auto_pct_value, 100))

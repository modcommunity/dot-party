class_name DotPartyBackend
extends RefCounted

## Where a party actually lives. Every change to one is asked of this, and every answer is
## a fresh snapshot.
##
## Two implementations: [DotPartyBackendApp] speaks to website-city as the signed-in
## player, and [DotPartyBackendLocal] runs the same rules in-process, for a LAN, an
## offline build and the suite. A game holds one and does not know which.
##
## [b]Every method may await.[/b] Call each as [code]await backend.join(...)[/code] even
## against the local one, which answers at once; a caller written against the local
## backend without the [code]await[/code] would break the day it is pointed at the site.
##
## [b]Refusals carry the site's own reason key[/b] in [member DotError.detail] —
## [code]party.join.deny.full[/code], [code]party.reserve.deny.window[/code] — because a
## client has copy and an affordance for each one, and a message it had to read English out
## of would leave it with neither. The local backend uses the same keys.

## The party this player is in, or a success whose value is null when they are in none.
func mine() -> DotResult:
	return _unsupported("mine")


func fetch(_party_id: String) -> DotResult:
	return _unsupported("fetch")


## [param options]: [code]{name, maxUsers, type, password, serverId, readyAutoPct,
## readyAutoSec, joinAfterStartPublic, joinAfterStartFriends}[/code], all optional —
## the site's own [code]CreatePartyInput[/code] field names.
func create(_options: Dictionary) -> DotResult:
	return _unsupported("create")


## Value: [code]{partyId, role, leftPartyId}[/code]. Joining one party leaves any other,
## because a person is in at most one live party; [code]leftPartyId[/code] says which.
func join(_party_id: String, _password: String = "", _token: String = "") -> DotResult:
	return _unsupported("join")


func leave(_party_id: String) -> DotResult:
	return _unsupported("leave")


## Keeps the membership alive. The site drops a member it has not heard from in 150
## seconds, so a client that stops heartbeating has left, whatever it believes.
func heartbeat(_party_id: String) -> DotResult:
	return _unsupported("heartbeat")


func kick(_party_id: String, _user_id: String, _ban: bool = false) -> DotResult:
	return _unsupported("kick")


func set_role(_party_id: String, _user_id: String, _role: DotPartyMember.Role) -> DotResult:
	return _unsupported("set_role")


func transfer_host(_party_id: String, _user_id: String) -> DotResult:
	return _unsupported("transfer_host")


## Value: the invite ids made. At most 25 people per call, as on the site.
func invite(_party_id: String, _user_ids: PackedStringArray, _message: String = "") -> DotResult:
	return _unsupported("invite")


## Value: pending invites to this player, each [code]{id, partyId, partyName, inviterId, message}[/code].
func invites() -> DotResult:
	return _unsupported("invites")


func respond_invite(_invite_id: String, _accept: bool) -> DotResult:
	return _unsupported("respond_invite")


## Opens the ready round on [param server_id]: stage READY, everybody is shown where to
## connect. 0 keeps the server the party already has.
func start(_party_id: String, _server_id: int = 0) -> DotResult:
	return _unsupported("start")


## Value: a [DotPartyReady].
func ready_state(_party_id: String) -> DotResult:
	return _unsupported("ready_state")


func set_ready(_party_id: String, _ready: bool = true) -> DotResult:
	return _unsupported("set_ready")


## Says this player's game has reached the server. What the ready screen's "connected" is.
func connected(_party_id: String) -> DotResult:
	return _unsupported("connected")


func force_start(_party_id: String) -> DotResult:
	return _unsupported("force_start")


## Abandons the ready round and goes back to the lobby.
func cancel_ready(_party_id: String) -> DotResult:
	return _unsupported("cancel_ready")


func end(_party_id: String) -> DotResult:
	return _unsupported("end")


## What [param server_id] can offer this party now: [code]{available, deny, allowPublic,
## allowPrivate, maxMinutes, freeAt}[/code].
func reservation_offer(_party_id: String, _server_id: int) -> DotResult:
	return _unsupported("reservation_offer")


## Books a server. Value: a [DotPartyReservation], PENDING when the owner approves by hand.
func reserve(_party_id: String, _server_id: int, _minutes: int, _private: bool = false) -> DotResult:
	return _unsupported("reserve")


func cancel_reservation(_reservation_id: String) -> DotResult:
	return _unsupported("cancel_reservation")


func describe() -> String:
	return "party backend"


func _unsupported(what: String) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "This party backend cannot %s." % what.replace("_", " "))

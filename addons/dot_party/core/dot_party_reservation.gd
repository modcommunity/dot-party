class_name DotPartyReservation
extends RefCounted

## A server booked for a party for a stretch of time.
##
## The backbone's [code]ServerPartyReservation[/code], field for field. [b]PRIVATE is the
## part that needs the game server.[/b] The site can promise a party that a server will be
## theirs; only the server can keep strangers out of it — and until this addon, nothing
## told the server. See [DotPartyReservations].

enum Status { PENDING, ACTIVE, ENDED, DENIED, CANCELLED, EXPIRED }

const STATUS_NAMES := ["PENDING", "ACTIVE", "ENDED", "DENIED", "CANCELLED", "EXPIRED"]

var id: String = ""
var server_id: int = 0
var party_id: String = ""
var requested_by: String = ""
var status: Status = Status.PENDING

## A private reservation admits the party and nobody else. A public one holds seats for
## the party while it arrives and otherwise leaves the server open.
var is_private: bool = false

## Unix seconds.
var starts_at: int = 0
var ends_at: int = 0
var released_at: int = 0

var note: String = ""


func is_active_at(now: int) -> bool:
	return status == Status.ACTIVE and now >= starts_at and now < ends_at


func seconds_left(now: int) -> int:
	return maxi(0, ends_at - now)


func status_name() -> String:
	return STATUS_NAMES[status]


static func parse_status(s: String) -> Status:
	var i := STATUS_NAMES.find(s.to_upper())
	return Status.PENDING if i < 0 else i as Status


static func from_dict(d: Dictionary) -> DotResult:
	var r := DotPartyReservation.new()
	r.id = str(d.get("id", ""))
	r.party_id = str(d.get("partyId", ""))
	if r.id == "" or not DotParty.is_id(r.party_id):
		return DotResult.fail(DotError.CODE_PARSE, "a reservation needs an id and a party id", str(d))
	r.server_id = int(d.get("serverId", 0)) if d.get("serverId") != null else 0
	r.requested_by = str(d.get("requestedById", "")) if d.get("requestedById") != null else ""
	r.status = parse_status(str(d.get("status", "PENDING")))
	r.is_private = bool(d.get("private", false))
	r.starts_at = DotPartyMember.parse_time(d.get("startsAt"))
	r.ends_at = DotPartyMember.parse_time(d.get("endsAt"))
	r.released_at = DotPartyMember.parse_time(d.get("releasedAt"))
	r.note = str(d.get("note", "")) if d.get("note") != null else ""
	if r.ends_at <= r.starts_at:
		return DotResult.fail(DotError.CODE_PARSE, "a reservation that ends before it starts", r.id)
	return DotResult.success(r)


func to_dict() -> Dictionary:
	return {
		"id": id,
		"serverId": server_id,
		"partyId": party_id,
		"requestedById": requested_by,
		"status": STATUS_NAMES[status],
		"private": is_private,
		"startsAt": DotPartyMember.format_time(starts_at),
		"endsAt": DotPartyMember.format_time(ends_at),
		"releasedAt": DotPartyMember.format_time(released_at),
		"note": note,
	}


func describe(now: int) -> String:
	return "reservation %s: party %s, %s, %s, %ds left" % [
		id, party_id, status_name(), "private" if is_private else "public", seconds_left(now),
	]

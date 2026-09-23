class_name DotPartyBackendLocal
extends DotPartyBackend

## One person's view of a [DotPartyLocalHub]. Get one with [method DotPartyLocalHub.as_user].

var hub: DotPartyLocalHub = null
var user_id: String = ""


func _init(p_hub: DotPartyLocalHub = null, p_user_id: String = "") -> void:
	hub = p_hub
	user_id = p_user_id


func mine() -> DotResult:
	return hub.mine(user_id)


func fetch(party_id: String) -> DotResult:
	return hub.fetch(party_id)


func create(options: Dictionary) -> DotResult:
	return hub.create(user_id, options)


func join(party_id: String, password: String = "", token: String = "") -> DotResult:
	return hub.join(user_id, party_id, password, token)


func leave(party_id: String) -> DotResult:
	return hub.leave(user_id, party_id)


func heartbeat(party_id: String) -> DotResult:
	return hub.heartbeat(user_id, party_id)


func kick(party_id: String, target: String, ban: bool = false) -> DotResult:
	return hub.kick(user_id, party_id, target, ban)


func set_role(party_id: String, target: String, role: DotPartyMember.Role) -> DotResult:
	return hub.set_role(user_id, party_id, target, role)


func transfer_host(party_id: String, target: String) -> DotResult:
	return hub.transfer_host(user_id, party_id, target)


func invite(party_id: String, user_ids: PackedStringArray, message: String = "") -> DotResult:
	return hub.invite(user_id, party_id, user_ids, message)


func invites() -> DotResult:
	return hub.invites_for(user_id)


func respond_invite(invite_id: String, accept: bool) -> DotResult:
	return hub.respond_invite(user_id, invite_id, accept)


func start(party_id: String, server_id: int = 0) -> DotResult:
	return hub.start(user_id, party_id, server_id)


func ready_state(party_id: String) -> DotResult:
	return hub.ready_view(user_id, party_id)


func set_ready(party_id: String, ready: bool = true) -> DotResult:
	return hub.set_ready(user_id, party_id, ready)


func connected(party_id: String) -> DotResult:
	return hub.connected(user_id, party_id)


func force_start(party_id: String) -> DotResult:
	return hub.force_start(user_id, party_id)


func cancel_ready(party_id: String) -> DotResult:
	return hub.cancel_ready(user_id, party_id)


func end(party_id: String) -> DotResult:
	return hub.end(user_id, party_id)


func reservation_offer(party_id: String, server_id: int) -> DotResult:
	return hub.reservation_offer(party_id, server_id)


func reserve(party_id: String, server_id: int, minutes: int, private: bool = false) -> DotResult:
	return hub.reserve(user_id, party_id, server_id, minutes, private)


func cancel_reservation(reservation_id: String) -> DotResult:
	return hub.cancel_reservation(user_id, reservation_id)


func describe() -> String:
	return "local party hub, as %s" % user_id

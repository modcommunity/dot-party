class_name DotPartyBackendApp
extends DotPartyBackend

## website-city, as the signed-in player.
##
## [b]Speaks a contract the site does not serve yet.[/b] The site's parties are complete —
## membership, invites, the ready round, reservations — but only through tRPC behind the
## website's session cookie, which a game client does not have. A game client holds an
## app token from dot-auth's device grant, and [code]/api/app/v1[/code] has no party routes
## at all. The routes this calls are specified in [code]docs/backbone-contract.md[/code]:
## each one is a thin wrapper over a function website-city already has
## ([code]JoinParty[/code], [code]LeaveParty[/code], [code]SetPartyReady[/code],
## [code]ReserveServerForParty[/code]…), with the site's own input names, so the site half
## is plumbing rather than design. Until it exists every call fails with a 404 that says so.
##
## [b]The app API's envelope, not the integration API's.[/b] [code]{ok: true, data}[/code]
## on success and [code]{ok: false, code, message, retryAfter}[/code] on failure, as
## [code]src/types/app-api/contract.ts[/code] defines it. The site's refusal key
## (a [code]party.join.deny.*[/code]) arrives as [code]code[/code] and lands in
## [member DotError.detail], where every other backend puts it.
##
## [b]Neither dot-auth nor its client is named.[/b] Give it [member client] — any object
## with [code]post_app(path, body)[/code] and [code]get_app(path, query)[/code], which is
## dot-auth's [code]DotAuthClient[/code] — and the token, its refresh and the envelope are
## all handled there, once, for every addon that speaks the app API. [member token_fn]
## with a [DotHttp] is the fallback for a game without dot-auth.

const CHANNEL := "party.app"

## Anything with [code]post_app(path, body)[/code] and [code]get_app(path, query)[/code]
## returning the envelope's data. Preferred over [member token_fn] when set.
var client: Object = null

## Where [code]/api/app/v1[/code] is, e.g. [code]https://tmc.example/api/app/v1[/code].
var api_base: String = ""

## [code]func() -> String[/code]: the current access token.
var token_fn: Callable = Callable()

## Does the requests. Needs to be in the tree; a game adds it once.
var http: DotHttp = null

## [code]func(method: String, path: String, body: Dictionary) -> DotResult[/code], replacing
## the HTTP call entirely. The suite uses it; so can a game with its own transport.
var request_fn: Callable = Callable()


func _init(p_api_base: String = "", p_http: DotHttp = null, p_token_fn: Callable = Callable()) -> void:
	api_base = p_api_base
	http = p_http
	token_fn = p_token_fn


func mine() -> DotResult:
	var res := await _call("GET", "party/mine")
	if not res.ok:
		return res
	var data: Variant = res.value
	if data == null or (data is Dictionary and (data as Dictionary).get("party") == null and not (data as Dictionary).has("id")):
		return DotResult.success(null)
	return DotParty.from_dict(data as Dictionary)


func fetch(party_id: String) -> DotResult:
	if not DotParty.is_id(party_id):
		return DotResult.fail(DotError.CODE_INVALID, "That is not a party id.", party_id)
	var res := await _call("GET", "party/%s" % party_id)
	if not res.ok:
		return res
	return DotParty.from_dict(res.value as Dictionary)


func create(options: Dictionary) -> DotResult:
	var res := await _call("POST", "party/create", options)
	if not res.ok:
		return res
	return DotParty.from_dict(res.value as Dictionary)


func join(party_id: String, password: String = "", token: String = "") -> DotResult:
	var body := {"id": party_id}
	if password != "":
		body["password"] = password
	if token != "":
		body["token"] = token
	return await _call("POST", "party/join", body)


func leave(party_id: String) -> DotResult:
	return await _call("POST", "party/leave", {"id": party_id})


func heartbeat(party_id: String) -> DotResult:
	return await _call("POST", "party/heartbeat", {"id": party_id})


func kick(party_id: String, user_id: String, ban: bool = false) -> DotResult:
	return await _call("POST", "party/kick", {"id": party_id, "userId": user_id, "ban": ban})


func set_role(party_id: String, user_id: String, role: DotPartyMember.Role) -> DotResult:
	return await _call("POST", "party/role", {
		"id": party_id, "userId": user_id, "role": DotPartyMember.ROLE_NAMES[role],
	})


func transfer_host(party_id: String, user_id: String) -> DotResult:
	return await _call("POST", "party/transfer", {"id": party_id, "userId": user_id})


func invite(party_id: String, user_ids: PackedStringArray, message: String = "") -> DotResult:
	if user_ids.size() > DotPartyLocalHub.INVITE_BATCH_MAX:
		return DotResult.fail(DotError.CODE_INVALID, "At most 25 people at once.", "party.invite.deny.batch")
	var body := {"id": party_id, "userIds": Array(user_ids)}
	if message != "":
		body["message"] = message
	return await _call("POST", "party/invite", body)


func invites() -> DotResult:
	return await _call("GET", "party/invites")


func respond_invite(invite_id: String, accept: bool) -> DotResult:
	return await _call("POST", "party/invite/respond", {"inviteId": invite_id, "accept": accept})


func start(party_id: String, server_id: int = 0) -> DotResult:
	var body := {"id": party_id}
	if server_id > 0:
		body["serverId"] = server_id
	return await _call("POST", "party/start", body)


func ready_state(party_id: String) -> DotResult:
	var res := await _call("GET", "party/%s/ready" % party_id)
	if not res.ok:
		return res
	return DotResult.success(DotPartyReady.from_dict(res.value as Dictionary))


func set_ready(party_id: String, ready: bool = true) -> DotResult:
	return await _call("POST", "party/ready", {"id": party_id, "ready": ready})


func connected(party_id: String) -> DotResult:
	return await _call("POST", "party/connected", {"id": party_id})


func force_start(party_id: String) -> DotResult:
	return await _call("POST", "party/force-start", {"id": party_id})


func cancel_ready(party_id: String) -> DotResult:
	return await _call("POST", "party/cancel", {"id": party_id})


func end(party_id: String) -> DotResult:
	return await _call("POST", "party/end", {"id": party_id})


func reservation_offer(party_id: String, server_id: int) -> DotResult:
	return await _call("GET", "party/%s/reserve/offer" % party_id, {}, {"serverId": server_id})


func reserve(party_id: String, server_id: int, minutes: int, private: bool = false) -> DotResult:
	var res := await _call("POST", "party/reserve", {
		"partyId": party_id, "serverId": server_id, "minutes": minutes, "private": private,
	})
	if not res.ok:
		return res
	return DotPartyReservation.from_dict(res.value as Dictionary)


func cancel_reservation(reservation_id: String) -> DotResult:
	return await _call("POST", "party/reserve/cancel", {"reservationId": reservation_id})


func describe() -> String:
	return "website-city at %s" % api_base


## One request, unwrapped from the app API's envelope. Value: the envelope's [code]data[/code].
func _call(method: String, path: String, body: Dictionary = {}, query: Dictionary = {}) -> DotResult:
	if request_fn.is_valid() or client == null:
		var full := path
		if not query.is_empty():
			var parts := PackedStringArray()
			for k in query:
				parts.append("%s=%s" % [str(k).uri_encode(), str(query[k]).uri_encode()])
			full += "?" + "&".join(parts)
		var raw: DotResult = null
		if request_fn.is_valid():
			raw = await request_fn.call(method, full, body)
		else:
			raw = await _http_call(method, full, body)
		if not raw.ok:
			return _explain(raw)
		if not (raw.value is Dictionary):
			return DotResult.fail(DotError.CODE_PARSE, "The party service answered with something that is not an object.")
		var env: Dictionary = raw.value
		if env.get("ok") == false:
			return _refusal(env, 0)
		return DotResult.success(env.get("data"))

	# Through dot-auth: the envelope is already unwrapped, and a refusal's site code is
	# already in the error's detail.
	var res: DotResult = null
	if method == "GET":
		res = await client.call("get_app", path, query)
	else:
		res = await client.call("post_app", path, body)
	if not res.ok and res.error != null and res.error.http_status == 404 and res.error.detail == "":
		return res.wrap("the site has no app party routes yet; see dot-party's docs/backbone-contract.md")
	return res


func _http_call(method: String, path: String, body: Dictionary) -> DotResult:
	if http == null:
		return DotResult.fail(DotError.CODE_STATE, "no HTTP client")
	if not token_fn.is_valid():
		return DotResult.fail(DotError.CODE_AUTH, "Sign in to use parties.")
	var token := str(token_fn.call())
	if token == "":
		return DotResult.fail(DotError.CODE_AUTH, "Sign in to use parties.")
	var url := api_base.trim_suffix("/") + "/" + path
	var headers := {"Authorization": "Bearer %s" % token}
	if method == "GET":
		return await http.get_json(url, headers)
	return await http.post_json(url, body, headers)


## A non-2xx carries the envelope in its body; lift the site's code and message out of it.
func _explain(raw: DotResult) -> DotResult:
	var e := raw.error
	if e == null:
		return raw
	var parsed: Variant = JSON.parse_string(e.detail) if e.detail != "" else null
	if parsed is Dictionary:
		return _refusal(parsed as Dictionary, e.http_status, e.code)
	if e.http_status == 404:
		return raw.wrap("the site has no app party routes yet; see dot-party's docs/backbone-contract.md")
	return raw


func _refusal(env: Dictionary, status: int, fallback_code: String = DotError.CODE_CONFLICT) -> DotResult:
	var site_code := str(env.get("code", ""))
	var message := str(env.get("message", "The party service refused."))
	var code := fallback_code
	if status == 0:
		code = DotError.CODE_CONFLICT
		if site_code == "unauthorized" or site_code == "wrong_credential":
			code = DotError.CODE_AUTH
		elif site_code.begins_with("rate"):
			code = DotError.CODE_RATE_LIMITED
	var err := DotError.make(code, message, site_code)
	err.http_status = status
	if env.get("retryAfter") != null:
		err.retry_after = float(env["retryAfter"])
	return DotResult.failure(err)

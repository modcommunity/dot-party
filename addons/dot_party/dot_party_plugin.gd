@tool
extends EditorPlugin

## Editor entry point for dot-party. Registers inspector types only.
##
## No autoloads: a server and a client share one process, and the suite has four people in
## one, and a global would make each of those one.

const _ICON := "res://addons/dot_party/icon_placeholder.svg"

const _TYPES := [
	[
		"DotPartyClient",
		"Node",
		"res://addons/dot_party/runtime/dot_party_client.gd",
	],
	[
		"DotPartyServer",
		"Node",
		"res://addons/dot_party/server/dot_party_server.gd",
	],
	[
		"DotPartyReservations",
		"Node",
		"res://addons/dot_party/server/dot_party_reservations.gd",
	],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for i in range(_TYPES.size() - 1, -1, -1):
		remove_custom_type(_TYPES[i][0])

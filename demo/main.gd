extends Node2D

const _locationCheckedTexture: Texture = preload("res://checked.png")

const GodotWebsocket = preload("res://bin/gdnative_yawc_wrapper.gdns")
const ApClient = preload("res://ap/godot_ap_client.gd")

# onready var _apClient: GodotApClientNew = $ApClient

onready var _apClient = $GodotApClient
onready var _connection = $ApWebSocketConnection
onready var _connectButton = $"%ConnectButton"
onready var _connectStatus: RichTextLabel = $"%ConnectStatus"
onready var _hostEdit: LineEdit = $"%HostEdit"
onready var _slotEdit: LineEdit = $"%SlotEdit"
onready var _gameEdit: LineEdit = $"%GameEdit"
onready var _passwordEdit: LineEdit = $"%PasswordEdit"
onready var _messageLog: RichTextLabel = $"%MessageLog"
onready var _locationsList: ItemList = $"%LocationsList"
onready var _items_list: ItemList = $"%ItemsList"
onready var _send_message_edit = $"%SendMessageEdit"
onready var _send_message_button = $"%SendMessageButton"
onready var _get_data_storage_key_edit = $"%GetDataStorageKeyEdit"
onready var _set_data_storage_key_edit = $"%SetDataStorageKeyEdit"

var _locations: Dictionary
var _location_names_sorted: Array

var _item_info: Dictionary = Dictionary()


func _ready():
	_apClient.set_client(_connection)
	update_connect_status(_apClient.connect_state)
	var status = _apClient.connect("connection_state_changed", self, "_on_ap_connection_state_changed")
	status = _apClient.connect("print_received", self, "_on_ap_print_received")
	status = _apClient.connect("room_updated", self, "_on_ap_room_update")
	status = _apClient.connect("item_received", self, "_on_ap_received_items")
	status = _apClient.connect("data_storage_updated", self, "_on_ap_ds_keys_received")


func update_connect_status(state: int):
	var state_str = ""
	match state:
		GodotApClient.ConnectState.DISCONNECTED:
			state_str = "Disconnected"
		GodotApClient.ConnectState.CONNECTING:
			state_str = "Connecting"
		GodotApClient.ConnectState.DISCONNECTING:
			state_str = "Disconnecting"
		GodotApClient.ConnectState.CONNECTED_TO_SERVER:
			state_str = "Connected (no slot)"
		GodotApClient.ConnectState.CONNECTED_TO_MULTIWORLD:
			state_str = "Connected"

	var msg = "Connect Status: %s" % state_str
	_connectStatus.set_bbcode(msg)
	
	if state == GodotApClient.ConnectState.DISCONNECTED:
		_connectButton.text = "Connect"
	else:
		_connectButton.text = "Disconnect"

func _on_ap_connection_state_changed(new_state, _error):
	update_connect_status(new_state)
	
	if new_state == GodotApClient.ConnectState.CONNECTED_TO_MULTIWORLD:
		_on_ap_connected_to_multiworld()

func _on_ap_connected_to_multiworld():
	_locations = Dictionary()
	_location_names_sorted = Array()

	var location_id_to_name = _apClient.player_data_package().location_id_to_name
	for loc in _apClient.missing_locations:
		var location_name = location_id_to_name[loc]
		_locations[location_name] = {
			"name": location_name,
			"id": loc,
			"checked": false
		}
		_location_names_sorted.append(location_name)

	for loc in _apClient.checked_locations:
		var location_name = location_id_to_name[loc]
		_locations[location_name] = {
			"name": location_name,
			"id": loc,
			"checked": true
		}
		_location_names_sorted.append(location_name)

	_location_names_sorted.sort()
	_populate_locations_list()
	_reset_item_info()
	_send_message_edit.editable = true

func _on_ap_room_update(room_update_info: Dictionary):
	var location_id_to_name = _apClient.player_data_package().location_id_to_name
	for location_id in room_update_info.get("checked_locations", []):
		var location_name = location_id_to_name[location_id]
		_locations[location_name]["checked"] = true
		var location_list_index = _location_names_sorted.bsearch(location_name)
		var items = _locationsList.items
		_locationsList.set_item_icon(location_list_index, _locationCheckedTexture)

func _populate_locations_list():
	_locationsList.clear()
	for location_name in _location_names_sorted:
		var item_texture = null
		if _locations[location_name]["checked"]:
			item_texture = _locationCheckedTexture
		_locationsList.add_item(location_name, item_texture)
	_locationsList.sort_items_by_text()

func _mark_location_checked_in_list(idx: int):
	_locationsList.set_item_icon(idx, _locationCheckedTexture)

func _send_message():
	var message = _send_message_edit.text
	if message:
		_apClient.websocket_client.say(message)
		_send_message_edit.clear()

func _on_ap_print_received(print_data: Dictionary):
	var message_type = print_data.get("type", null)
	var message_parts = print_data["data"]
	var message_parts_formatted = PoolStringArray([])
	for part in message_parts:
		var content_type = part.get("type", "text")
		var content_data = part["text"]
		var content_text = str(content_data)
		# Adapted from https://github.com/ArchipelagoMW/Archipelago/blob/main/NetUtils.py#L225
		match content_type:
			"text":
				content_text = content_data
			"player_id":
				var player_slot = int(content_data)
				var player_color = "#FAFAD2"; # yellow
				if player_slot == _apClient.slot:
					player_color = "#EE00EE"
				var player_name = _apClient.players[player_slot - 1]["alias"]
				content_text = "[color=%s]%s[/color]" % [player_color, player_name]
			"player_name":
				content_text = "[color=yellow]%s[/color]" % content_data
			"item_id":
				# Flags is parsed as a float by default
				var item_flags = int(print_data["item"]["flags"])
				var item_color = "#00EEEE" # cyan
				if item_flags & 0b001: # Advancement
					item_color = "#AF99EF" # plum
				elif item_flags & 0b010: # Useful
					item_color = "#6D8BE8" # slateblue
				elif item_flags & 0b100: # Trap
					item_color = "#FA8072" # salmon

				var item_id = float(part["text"])
				var item_slot = str(part["player"])
				var item_slot_type = typeof(item_slot)
				var item_game = _apClient.slot_info[item_slot]["game"]
				var item_name = _apClient.data_package[item_game].item_id_to_name[item_id]
				content_text = "[b][color=%s]%s[/color][/b]" % [item_color, item_name]
			"location_id":
				var location_id = float(part["text"])
				var location_name = _apClient.player_data_package().location_id_to_name[location_id]
				content_text = "[b][color=green]%s[/color][/b]" % location_name
			"entrance_name":
				content_text = "[b][color=blue]%s[/color][/b]" % content_data
			"color":
				content_text = "<COLOR: %s>%s</COLOR>" % [content_data["color"], content_data["text"]]
			_:
				content_text = "<UNKNOWN TYPE>%s<UNKNOWN>" % content_data
		message_parts_formatted.append(content_text)

	var message = "".join(message_parts_formatted) + "\n"
	_messageLog.append_bbcode(message)

func _on_ap_ds_keys_received(key: String, new_value, original_value):
	print("Got ds keys")
	if key == "big_string":
		var big_string_len = new_value.length()
		_get_data_storage_key_edit.text = String(big_string_len)

func _reset_item_info():
	_item_info.clear()
	_items_list.clear()

func _on_ap_received_items(item_name: String, item: Dictionary):
	if _item_info.has(item_name):
		_item_info[item_name]["count"] += 1
		var new_item_text = "%s: %d" % [item_name, _item_info[item_name]["count"]]
		_items_list.set_item_text(_item_info[item_name]["list_index"], new_item_text)
	else:
		var item_list_index = len(_item_info)
		_item_info[item_name] = {
			"item": item,
			"count": 1,
			"list_index": item_list_index
		}
		var new_item_text = "%s: %d" % [item_name, 1]
		_items_list.add_item(new_item_text)

func _unhandled_input(event):
	if event is InputEventKey:
		if event.scancode == KEY_ENTER and _send_message_edit.has_focus():
			_send_message()

func _on_ConnectButton_pressed():
	if _apClient.connect_state != GodotApClient.ConnectState.DISCONNECTED:
		_apClient.disconnect_from_multiworld()
	else:
		var host = _hostEdit.text
		var slot = _slotEdit.text
		var game = _gameEdit.text
		var password = _passwordEdit.text

		if host.empty() or host == null:
			print("ERROR: Host not set, can't connect!")
			return
		if slot.empty() or slot == null:
			print("ERROR: Slot not set, can't connect!")
			return

		_apClient.player = slot
		_apClient.server = host
		_apClient.game = game
		_apClient.password = password
		_apClient.connect_to_multiworld()

func _on_CheckLocationsButton_pressed():
	var location_idx = _locationsList.get_selected_items()
	var locations = []

	var player_data_package = _apClient.player_data_package()
	for idx in location_idx:
		var location_name = _locationsList.get_item_text(idx)
		var location_id = player_data_package.location_name_to_id[location_name]
		locations.append(location_id)
		_mark_location_checked_in_list(idx)

	print("Checking locations: %s" % ", ".join(locations))
	_apClient.check_location(locations)

func _on_SendMessageEdit_text_changed(new_text):
	_send_message_button.disabled = new_text == "";

func _on_SendMessageButton_pressed():
	_send_message();

func _on_SetDataStorageKeyButton_pressed():
	var num_zeros = int(_set_data_storage_key_edit.text)
	if num_zeros != null and num_zeros > 0:
		var big_string = "0".repeat(num_zeros)
		_apClient.set_value("big_string", ["replace"], [big_string], null, true)

func _on_GetDataStorageKeyButton_pressed():
	_apClient.get_value(["big_string"])

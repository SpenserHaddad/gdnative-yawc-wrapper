extends Node2D

const _locationCheckedTexture: Texture = preload("res://checked.png")

const GodotWebsocket = preload("res://bin/gdnative_yawc_wrapper.gdns")
const ApClient = preload("res://ap/godot_ap_client.gd")

# onready var _apClient: GodotApClientNew = $ApClient

onready var _apClient: GodotApClient = $GodotApClient
onready var _connection = $ApWebSocketConnection
#onready var _websocket = $Websocket
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
	var gdn = GDNative.new()
	gdn.library = load("res://bin/gdnative_yawc_wrapper_lib.gdnlib")
	gdn.initialize()
	
	var ws_script = NativeScript.new()
	ws_script.set_library(gdn.library)
	ws_script.set_class_name("GodotWebsocket")
	
	var _websocket = ws_script.new()
	
	print("Setup GodotWebsocket, debug_value is %d, get_connection_status is %s" % [_websocket.debug_value, _websocket.get_connection_status()])
	
	_connection.set_websocket(_websocket)
	_apClient.set_client(_connection)
	update_connect_status(_apClient.connect_state)
	var status = _apClient.connect("connection_state_changed", self, "_on_ap_connection_state_changed")
	status = _apClient.websocket_client.connect("print_received", self, "_on_ap_print_received")
	status = _apClient.websocket_client.connect("checked_locations", self, "_on_ap_checked_locations")
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

func _on_ap_connection_state_changed(new_state, _error):
	update_connect_status(new_state)
	
	if new_state == GodotApClient.ConnectState.CONNECTED_TO_MULTIWORLD:
		_on_ap_connected_to_multiworld()

func _on_ap_connected_to_multiworld():
	_locations = Dictionary()
	_location_names_sorted = Array()

	for loc in _apClient.missing_locations:
		var location_name = _apClient.data_package.location_id_to_name[loc]
		_locations[location_name] = {
			"name": location_name,
			"id": loc,
			"checked": false
		}
		_location_names_sorted.append(location_name)

	for loc in _apClient.checked_locations:
		var location_name = _apClient.data_package.location_id_to_name[loc]
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

func _on_ap_checked_locations(locations):
	for loc in locations:
		_locations[loc["name"]]["checked"] = true
		var location_list_index = _location_names_sorted.bsearch(loc)
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
	var message_type = print_data.keys()[0]
	var message_parts = print_data[message_type]["data"]
	var message_parts_formatted = PoolStringArray([])
	for part in message_parts:
		var content_type = part.keys()[0]
		var content_data = part[content_type]
		var content_text = str(content_data)
		# Adapted from https://github.com/ArchipelagoMW/Archipelago/blob/main/NetUtils.py#L225
		match content_type:
			"Text":
				content_text = content_data
			"Player":
				var player_slot = content_data["slot"]
				var player_color = "#FAFAD2"; # yellow
				if player_slot == _apClient.get_slot():
					player_color = "#EE00EE"
				content_text = "[color=%s]%s[/color]" % [player_color, content_data["alias"]]
			"PlayerName":
				content_text = "[color=yellow]%s[/color]" % content_data
			"Item":
				var item_flags = print_data[message_type]["item"]["flags"]
				var item_color = "#00EEEE" # cyan
				if item_flags & 0b001: # Advancement
					item_color = "#AF99EF" # plum
				elif item_flags & 0b010: # Useful
					item_color = "#6D8BE8" # slateblue
				elif item_flags & 0b100: # Trap
					item_color = "#FA8072" # salmon

				content_text = "[b][color=%s]%s[/color][/b]" % [item_color, content_data["item"]["name"]]
			"Location":
				content_text = "[b][color=green]%s[/color][/b]" % content_data["location"]["name"]
			"EntranceName":
				content_text = "[b][color=blue]%s[/color][/b]" % content_data
			"Color":
				content_text = "<COLOR: %s>%s</COLOR>" % [content_data["color"], content_data["text"]]
			_:
				content_text = "<UNKNOWN TYPE>%s<UNKNOWN>" % content_data
		message_parts_formatted.append(content_text)

	var message = "".join(message_parts_formatted) + "\n"
	_messageLog.append_bbcode(message)

func _on_ap_ds_keys_received(key: String, old_value, new_value):
	print("Got ds keys")
	if key == "big_string":
		var big_string_len = new_value.length()
		_get_data_storage_key_edit.text = String(big_string_len)

func _reset_item_info():
	_item_info.clear()
	_items_list.clear()

func _on_ap_received_items(_idx: int, items: Array):
	for item in items:
		var item_name = item["item"]["item"]["name"]
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

	for idx in location_idx:
		locations.append(_locationsList.get_item_text(idx))
		_mark_location_checked_in_list(idx)

	print("Checking locations: %s" % ", ".join(locations))
	_apClient.websocket_client.check_locations(locations)

func _on_SendMessageEdit_text_changed(new_text):
	_send_message_button.disabled = new_text == "";

func _on_SendMessageButton_pressed():
	_send_message();

func _on_SetDataStorageKeyButton_pressed():
	var num_zeros = int(_set_data_storage_key_edit.text)
	if num_zeros != null and num_zeros > 0:
		var big_string = "0".repeat(num_zeros)
		_apClient.websocket_client.set_value("big_string", big_string, true)

func _on_GetDataStorageKeyButton_pressed():
	_apClient.websocket_client.get_value(["big_string"])

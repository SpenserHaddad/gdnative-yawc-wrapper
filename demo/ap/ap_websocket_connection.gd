extends Node
class_name ApWebSocketConnection

enum State {
	STATE_CONNECTING = 0
	STATE_OPEN = 1
	STATE_CLOSING = 2
	STATE_CLOSED = 3
}

# Hard-code mod name to avoid cyclical dependency
const LOG_NAME = "RampagingHippy-Archipelago/ap_websocket_connection"
const _DEFAULT_PORT = 38281
const _CONNECT_TIMEOUT_SECONDS = 5

# The client handles connecting to the server, and the peer handles sending/receiving
# data after connecting. We set the peer in the "_on_connection_established" callback,
# and clear it in the "_on_connection_closed" callback.
var _client
var _url: String
var _waiting_to_connect_to_server = null

var _websocket_factory

var connection_state = State.STATE_CLOSED

signal connection_state_changed
signal on_connected(connection_data)
signal on_connection_refused(refused_reason)
signal on_room_info(room_info)
signal on_received_items
signal on_location_info
signal on_room_update
signal on_print_json
signal on_data_package
signal on_bounced
signal on_invalid_packet
signal on_retrieved
signal on_set_reply

signal _stop_waiting_to_connect(success)

func _ready():
	# Always process so we don't disconnect if the game is paused for too long.
	pause_mode = Node.PAUSE_MODE_PROCESS
	var gdn = GDNative.new()
	gdn.library = load("res://bin/gdnative_yawc_wrapper_lib.gdnlib")
	gdn.initialize()

	var factory_script = NativeScript.new()
	factory_script.set_library(gdn.library)
	factory_script.set_class_name("GodotWebsocketFactory")

	_websocket_factory = factory_script.new()

# Public API
func _set_websocket(websocket):
	if self._client != null:
		# Disconnect signals from the old client reference
		self._client.disconnect("connection_closed", self, "_on_connection_closed")
		self._client.disconnect("data_received", self, "_on_data_received")
		self._client.disconnect("connection_established", self, "_on_connection_established")
		self._client.disconnect("connection_error", self, "_on_connection_error")
	self._client = websocket

	# Connect base signals to get notified of connection open, close, and errors.
	var _result = self._client.connect("connection_closed", self, "_on_connection_closed")
	_result = self._client.connect("data_received", self, "_on_data_received")
	_result = self._client.connect("connection_established", self, "_on_connection_established")
	_result = self._client.connect("connection_error", self, "_on_connection_error")

#	_result = _client.set_buffers(80 * 1024 * 1024, 80 * 1024 * 1024)

func connect_to_server(server: String) -> bool:
	if connection_state == State.STATE_OPEN:
		return true
	_set_connection_state(State.STATE_CONNECTING)

	# TODO: It would be nice to move a lot of this into a separate factory class so we
	# didn't have to duplicate code for the WSS and WS cases, and so we don't have
	# methods that all only called a specific times which could otherwise be discarded.
	# But, my one attempt at doing so led to weird cases where the WS client didn't
	# correctly perform the handshake with the server.

	# Use the default Archipelago port if not included in the URL
	var port_check_pattern = RegEx.new()
	port_check_pattern.compile(":(\\d+)$")
	var server_has_port = port_check_pattern.search(server)
	if not server_has_port:
		server = "%s:%d" % [server, _DEFAULT_PORT]

	# Try to connect with SSL first
	var wss_url = "wss://%s" % [server]

	# Create a timeout to trigger the done waiting signal if we take too long
	_waiting_to_connect_to_server = wss_url
	var wss_connect_async_state = _websocket_factory.connect_to_url(wss_url)

	var wss_connect_result = yield(wss_connect_async_state, "completed")
	var wss_connect_error = wss_connect_result.get("Err", null)
	var wss_success = wss_connect_error == null
	print("wss_success: %s, error: %s" % [wss_success, wss_connect_error])

	var ws_success = false
	if not wss_success:
		# We don't have any info on why the connection failed (thanks Godot), so we
		# assume it was because the server doesn't support SSL. So, try connecting using
		# "ws://" instead.
		print("Connecting with WSS failed, trying WS.")
		var ws_url = "ws://%s" % [server]
		_waiting_to_connect_to_server = ws_url
		var ws_connect_async_state = _websocket_factory.connect_to_url(ws_url)

		var ws_connect_result = yield(ws_connect_async_state, "completed")
		var ws_connect_error = ws_connect_result.get("Err", null)
		ws_success = ws_connect_error == null
		print("ws_success: %s, error: %s" % [ws_success, ws_connect_error])

		_waiting_to_connect_to_server = null
		if ws_success:
			_url = ws_url
			_set_websocket(ws_connect_result["Ok"])
	else:
		_url = wss_url
		_set_websocket(wss_connect_result["Ok"])

	if wss_success or ws_success:
		_set_connection_state(State.STATE_OPEN)
		print("Connected to multiworld %s." % _url)

	return wss_success or ws_success

func connected_to_server() -> bool:
	return connection_state == State.STATE_OPEN

func disconnect_from_server():
	if connection_state == State.STATE_CLOSED:
		return
	_set_connection_state(State.STATE_CLOSING)
	# The "connection_closed" signal handler will take care of cleanup
	_client.disconnect_from_host()

func send_connect(game: String, user: String, password: String = "", slot_data: bool = true, tags: Array = []):
	_send_command({
		"cmd": "Connect",
		"game": game,
		"name": user,
		"password": password,
		"uuid": "60c9c15c-4f9b-4bcd-9512-abd53eeccc81",
		"version": {"major": 0, "minor": 6, "build": 2, "class": "Version"},
		"items_handling": 0b111, # TODO: argument
		"tags": tags,
		"slot_data": slot_data
	})

func send_connect_update(items_handling: int = -1, tags = null):
	var args = {"cmd": "ConnectUpdate"}
	if items_handling >= 0:
		args["items_handling"] = items_handling
	if tags != null:
		args["tags"] = tags
	_send_command(args)

func send_sync():
	_send_command({"cmd": "Sync"})

func send_location_checks(locations: Array):
	var location_strs = []
	for loc in locations:
		location_strs.append(str(loc))
	_send_command(
		{
			"cmd": "LocationChecks",
			"locations": locations,
		}
	)

# TODO: create_as_hint Enum
func send_location_scouts(locations: Array, create_as_int: int):
	var location_strs = []
	for loc in locations:
		location_strs.append(str(loc))
	_send_command({
		"cmd": "LocationScouts",
		"locations": locations,
		"create_as_int": create_as_int
	})

func status_update(status: int):
	_send_command({
		"cmd": "StatusUpdate",
		"status": status,
	})

func say(text: String):
	_send_command({
		"cmd": "Say",
		"text": text,
	})

func get_data_package(games: Array):
	_send_command({
		"cmd": "GetDataPackage",
		"games": games,
	})

func send_bounce(data: Dictionary, games: Array = [], slots: Array = [], tags: Array = []):
	var args = {"cmd": "Bounce", "data": data}
	if games.size() > 0:
		args["games"] = games
	if slots.size() > 0:
		args["slots"] = slots
	if tags.size() > 0:
		args["tags"] = tags

	_send_command(args)

# TODO: Extra custom arguments
func get_value(keys: Array):
	# This is Archipelago's "Get" command, we change the name
	# since "get" is already taken by "Object.get".
	_send_command({
		"cmd": "Get",
		"keys": keys,
	})

# TODO: DataStorageOperation data type
func set_value(key: String, default, want_reply: bool, operations: Array):
	var op_names = []
	for op in operations:
		op_names.append(op["operation"])
	var _ops = ", ".join(op_names)
	_send_command({
		"cmd": "Set",
		"key": key,
		"default": default,
		"want_reply": want_reply,
		"operations": operations,
	})

func set_notify(keys: Array):
	_send_command({
		"cmd": "SetNotify",
		"keys": keys,
	})

# WebSocketClient callbacks
func _on_connection_established(_proto = ""):
	# We succeeded, stop waiting and tell the caller.
	print("Successfully connected.")
	emit_signal("_stop_waiting_to_connect", true)

func _on_connection_error():
	# We failed, stop waiting and tell the caller.
	print("Connection error.")
	emit_signal("_stop_waiting_to_connect", false)

func _on_connection_closed(was_clean = false):
	print("AP connection closed, clean: %s." % was_clean)
	_set_connection_state(State.STATE_CLOSED)
	# _peer = null

func _on_data_received(received_data_str: String):
	# if self._peer == null:
	# 	# Rare case where we have a dead connection to a server that suddenly
	# 	# becomes active. Just ignore because we're not setup for it.
	# 	print("Received data from server even though peer is not setup.")
	# 	return
	# var received_data_str = _peer.get_packet().get_string_from_utf8()
	var received_data = JSON.parse(received_data_str)
	if received_data.result == null:
		print("Failed to parse JSON for %s" % received_data_str)
		return
#	ModLoaderLog.debug("Received payload with size %d" % received_data_str.length(), LOG_NAME)
	for command in received_data.result:
		_handle_command(command)

# Internal plumbing
func _send_command(args: Dictionary):
#	if args['cmd'] == 'Set':
#		ModLoaderLog.debug("Sending %s command for %s" % [args['cmd'], args['key']], LOG_NAME)
#	else:
#		ModLoaderLog.debug("Sending %s command" % args['cmd'], LOG_NAME)
	var command_str = JSON.print([args])
	_client.send(command_str)
	# if _peer != null:
	# 	var result = _peer.put_packet(command_str.to_utf8())
	# 	if result != 0:
	# 		var gpe = _peer.get_packet_error()
	# 		var client_state = _client.get_connection_status()
	# 		print("Failed to send command, put_packet response is %d, gpe is %d, client_status is %s" % [result, gpe, client_state])
	# else:
	# 	print("Peer is null!")

#func _init_client():
#	if self._client != null:
#		# Disconnect signals from the old client reference
#		self._client.disconnect("connection_closed", self, "_on_connection_closed")
#		self._client.disconnect("data_received", self, "_on_data_received")
#		self._client.disconnect("connection_established", self, "_on_connection_established")
#		self._client.disconnect("connection_error", self, "_on_connection_error")
#	self._client = WebSocketClient.new()
#
#	# Connect base signals to get notified of connection open, close, and errors.
#	var _result = self._client.connect("connection_closed", self, "_on_connection_closed")
#	_result = self._client.connect("data_received", self, "_on_data_received")
#	_result = self._client.connect("connection_established", self, "_on_connection_established")
#	_result = self._client.connect("connection_error", self, "_on_connection_error")

	# Increase max buffer size to accommodate AP's larger payloads. The args
	# and their defaults are:
	#	- input_buffer_size_kb = 64 KB
	#	- input_max_packets = 1024
	#	- output_buffer_size_kb = 64 KB
	#	- output_max_packets = 1024
	# We increase the input buffer to 80 MB because some messages we receive
	# are too large	for 64K. It's huge, but it being too small has caused some
	# nasty bugs in the past. The other defaults have been fine though.
	# Hopefully once the compression update propagates we can turn this down to
	# like ~5 MB.
	# NOTE: Godot will silently drop packets that do not fit in the buffer! This
	# can cause the WebSocket connection to time out because the messaging is
	# not complete. If the game mysteriously drops the connection a few seconds
	# after connecting, the buffer likely needs to be larger.
#	_result = _client.set_buffers(1024 * 80, 2048, 1024 * 80, 2048)
#	if _result:
#		print("Failed to set buffer sizes with error %d" % _result)

	# self._peer = null

func _make_connection_timeout(for_url: String):
	yield (get_tree().create_timer(_CONNECT_TIMEOUT_SECONDS), "timeout")
	if _waiting_to_connect_to_server == for_url:
		# We took to long, stop waiting and tell the called we failed.
		_waiting_to_connect_to_server = false
		print("Timed out trying to connect.")
		emit_signal("_stop_waiting_to_connect", false)

func _set_connection_state(state):
	var state_name = State.keys()[state]
	print("AP connection state changed to: %s." % state_name)
	connection_state = state
	emit_signal("connection_state_changed", connection_state)

func _handle_command(command: Dictionary):
	print("Received %s command" % command["cmd"])
	match command["cmd"]:
		"RoomInfo":
			emit_signal("on_room_info", command)
		"ConnectionRefused":
			emit_signal("on_connection_refused", command)
		"Connected":
			emit_signal("on_connected", command)
		"ReceivedItems":
			emit_signal("on_received_items", command)
		"LocationInfo":
			emit_signal("on_location_info", command)
		"RoomUpdate":
			emit_signal("on_room_update", command)
		"PrintJSON":
			emit_signal("on_print_json", command)
		"DataPackage":
			emit_signal("on_data_package", command)
		"Bounced":
			emit_signal("on_bounced", command)
		"InvalidPacket":
			emit_signal("on_invalid_packet", command)
		"Retrieved":
			emit_signal("on_retrieved", command)
		"SetReply":
			emit_signal("on_set_reply", command)
		_:
			print("Received Unknown Command %s" % command["cmd"])

func _process(_delta):
	# Only run when the connection the the server is not closed.
	if _client != null:
		var state = _client.poll()
		yield(state, "completed")

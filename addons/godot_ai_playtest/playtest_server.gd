extends Node
## PlaytestServer - TCP/JSON-RPC server for AI-assisted playtesting
##
## Exposes game state and controls to external tools. Only active in debug builds.
## Connect via TCP on localhost:9876 (configurable).
##
## Inspired by GodotTestDriver patterns for input simulation and wait conditions.

const VERSION := "0.3.0"
const DEFAULT_PORT := 9876
const BUFFER_SIZE := 65536

# Configuration
var port: int = DEFAULT_PORT
var enabled: bool = true
var allow_execute: bool = true  # Allow arbitrary GDScript execution (dangerous!)

# Server state
var _server: TCPServer
var _clients: Array[StreamPeerTCP] = []
var _client_buffers: Dictionary = {}  # client -> String buffer

# Active input holds (action_name -> release_time_ms)
var _held_actions: Dictionary = {}

# Performance tracking
var _frame_times: Array[float] = []
var _max_frame_samples: int = 120  # ~2 seconds at 60fps

# Error/warning capture
var _captured_errors: Array[Dictionary] = []
var _capture_errors: bool = false

# Recording state
var _recording: bool = false
var _recorded_inputs: Array[Dictionary] = []
var _recording_start_ms: int = 0

# Visual regression baselines directory
var _baselines_dir: String = "user://playtest_baselines"

# Signals for game integration
signal client_connected(client_id: int)
signal client_disconnected(client_id: int)
signal command_received(method: String, params: Dictionary)


func _ready() -> void:
	if not OS.is_debug_build():
		print("[PlaytestServer] Disabled in release build")
		set_process(false)
		return
	
	if not enabled:
		print("[PlaytestServer] Disabled by configuration")
		set_process(false)
		return
	
	_start_server()
	
	# Ensure baselines directory exists
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_baselines_dir))


func _start_server() -> void:
	_server = TCPServer.new()
	var err := _server.listen(port, "127.0.0.1")
	
	if err != OK:
		push_error("[PlaytestServer] Failed to start on port %d: %s" % [port, error_string(err)])
		return
	
	print("[PlaytestServer] Listening on localhost:%d (v%s)" % [port, VERSION])


func _process(delta: float) -> void:
	_accept_new_clients()
	_process_clients()
	_process_held_actions()
	_track_frame_time(delta)
	_record_frame_if_active()


func _track_frame_time(delta: float) -> void:
	_frame_times.append(delta * 1000.0)  # Convert to ms
	if _frame_times.size() > _max_frame_samples:
		_frame_times.pop_front()


func _record_frame_if_active() -> void:
	if not _recording:
		return
	# Recording happens in input handlers


func _accept_new_clients() -> void:
	while _server and _server.is_connection_available():
		var client := _server.take_connection()
		if client:
			_clients.append(client)
			_client_buffers[client] = ""
			client_connected.emit(client.get_instance_id())


func _process_clients() -> void:
	var disconnected: Array[StreamPeerTCP] = []
	
	for client in _clients:
		if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			disconnected.append(client)
			continue
		
		var available := client.get_available_bytes()
		if available > 0:
			var data := client.get_data(mini(available, BUFFER_SIZE))
			if data[0] == OK:
				_client_buffers[client] += data[1].get_string_from_utf8()
				_process_buffer(client)
	
	for client in disconnected:
		_disconnect_client(client)


func _process_buffer(client: StreamPeerTCP) -> void:
	var buffer: String = _client_buffers[client]
	
	while "\n" in buffer:
		var idx := buffer.find("\n")
		var line := buffer.substr(0, idx).strip_edges()
		buffer = buffer.substr(idx + 1)
		
		if not line.is_empty():
			_handle_request(client, line)
	
	_client_buffers[client] = buffer


func _disconnect_client(client: StreamPeerTCP) -> void:
	client_disconnected.emit(client.get_instance_id())
	_clients.erase(client)
	_client_buffers.erase(client)


func _handle_request(client: StreamPeerTCP, json_str: String) -> void:
	var json := JSON.new()
	var err := json.parse(json_str)
	
	if err != OK:
		_send_error(client, null, -32700, "Parse error")
		return
	
	var request: Dictionary = json.data
	var id = request.get("id")
	var method: String = request.get("method", "")
	var params: Dictionary = request.get("params", {})
	
	if method.is_empty():
		_send_error(client, id, -32600, "Invalid request: missing method")
		return
	
	command_received.emit(method, params)
	var result: Variant = _handle_method(client, method, params)
	
	if result is Dictionary and result.has("error"):
		_send_response(client, id, null, result["error"])
	else:
		_send_response(client, id, result)


func _send_response(client: StreamPeerTCP, id: Variant, result: Variant = null, error: Variant = null) -> void:
	var response := {
		"jsonrpc": "2.0",
		"id": id
	}
	
	if error != null:
		response["error"] = error
	else:
		response["result"] = result
	
	var json_str := JSON.stringify(response) + "\n"
	client.put_data(json_str.to_utf8_buffer())


func _send_error(client: StreamPeerTCP, id: Variant, code: int, message: String) -> void:
	_send_response(client, id, null, {"code": code, "message": message})


# =============================================================================
# Method Handlers
# =============================================================================

func _handle_method(_client: StreamPeerTCP, method: String, params: Dictionary) -> Variant:
	match method:
		# Core
		"ping":
			return {"pong": true, "version": VERSION}
		"get_state":
			return _get_state(params)
		
		# Input
		"send_input":
			return _send_input(params)
		"hold_action":
			return _hold_action(params)
		"release_action":
			return _release_action(params)
		"click_at":
			return _click_at(params)
		"move_mouse":
			return _move_mouse(params)
		
		# Visual
		"screenshot":
			return _screenshot(params)
		"compare_screenshot":
			return _compare_screenshot(params)
		"save_baseline":
			return _save_baseline(params)
		
		# Query
		"query":
			return _query(params)
		"wait_for":
			return _wait_for(params)
		
		# Scene/Node Control
		"scene_change":
			return _scene_change(params)
		"call_method":
			return _call_method(params)
		"execute":
			if not allow_execute:
				return {"error": {"code": -32601, "message": "execute disabled"}}
			return _execute(params)
		
		# Time Control
		"time_advance":
			return _time_advance(params)
		"time_set":
			return _time_set(params)
		"time_pause":
			return _time_pause(params)
		"time_resume":
			return _time_resume(params)
		
		# NPC State
		"get_npc":
			return _get_npc(params)
		"get_all_npcs":
			return _get_all_npcs(params)
		
		# Inventory
		"get_inventory":
			return _get_inventory(params)
		"add_item":
			return _add_item(params)
		"remove_item":
			return _remove_item(params)
		
		# Save/Load
		"save_game":
			return _save_game(params)
		"load_game":
			return _load_game(params)
		"list_saves":
			return _list_saves(params)
		"delete_save":
			return _delete_save(params)
		
		# Performance
		"get_performance":
			return _get_performance(params)
		"assert_performance":
			return _assert_performance(params)
		
		# Error Capture
		"start_error_capture":
			return _start_error_capture(params)
		"stop_error_capture":
			return _stop_error_capture(params)
		"get_captured_errors":
			return _get_captured_errors(params)
		
		# Recording
		"start_recording":
			return _start_recording(params)
		"stop_recording":
			return _stop_recording(params)
		"playback":
			return _playback(params)
		
		# World/Tile Query
		"get_tile":
			return _get_tile(params)
		"get_tiles_in_radius":
			return _get_tiles_in_radius(params)
		"get_entities_at":
			return _get_entities_at(params)
		
		# NPC Interaction
		"interact_npc":
			return _interact_npc(params)
		"give_gift":
			return _give_gift(params)
		"talk_to_npc":
			return _talk_to_npc(params)
		
		# Teleport
		"teleport_to":
			return _teleport_to(params)
		"teleport_to_npc":
			return _teleport_to_npc(params)
		
		# Weather Control
		"get_weather":
			return _get_weather(params)
		"set_weather":
			return _set_weather(params)
		
		# Goal/Quest System
		"get_goals":
			return _get_goals(params)
		"get_npc_goal":
			return _get_npc_goal(params)
		"complete_goal":
			return _complete_goal(params)
		
		# Spawning
		"spawn_item":
			return _spawn_item(params)
		
		_:
			return {"error": {"code": -32601, "message": "Method not found: " + method}}


# =============================================================================
# State Inspection
# =============================================================================

func _get_state(params: Dictionary) -> Dictionary:
	var include_npcs: bool = params.get("include_npcs", true)
	var include_inventory: bool = params.get("include_inventory", false)
	var include_performance: bool = params.get("include_performance", false)
	
	var state := {
		"version": VERSION,
		"timestamp_ms": Time.get_ticks_msec(),
		"scene": _get_scene_info(),
		"world": _get_world_info(),
		"ui": _get_ui_info(),
		"custom": {}
	}
	
	# Add player info if available
	var player := _find_player()
	if player:
		state["player"] = _get_player_info(player)
		state["camera"] = _get_camera_info()
		if include_npcs:
			state["npcs"] = _get_npcs_info()
	
	if include_inventory:
		state["inventory"] = _get_inventory({})
	
	if include_performance:
		state["performance"] = _get_performance({})
	
	return state


func _get_scene_info() -> Dictionary:
	var current := get_tree().current_scene
	return {
		"name": current.name if current else "",
		"current": current.scene_file_path if current else ""
	}


func _get_world_info() -> Dictionary:
	var info := {
		"game_state": "UNKNOWN",
		"game_mode": "UNKNOWN",
		"session_mode": "UNKNOWN",
		"time": {},
		"world_seed": 0,
		"profile_id": ""
	}
	
	# Try GameManager autoload
	if has_node("/root/GameManager"):
		var gm = get_node("/root/GameManager")
		
		# GameState enum: MENU=0, PLAYING=1, PAUSED=2
		if "game_state" in gm:
			match int(gm.game_state):
				0: info["game_state"] = "MENU"
				1: info["game_state"] = "PLAYING"
				2: info["game_state"] = "PAUSED"
				_: info["game_state"] = str(gm.game_state)
		
		# GameMode enum: SURVIVAL=0, CREATIVE=1
		if "game_mode" in gm:
			match int(gm.game_mode):
				0: info["game_mode"] = "SURVIVAL"
				1: info["game_mode"] = "CREATIVE"
				_: info["game_mode"] = str(gm.game_mode)
		
		# SessionMode enum: SINGLE_PLAYER=0, HOSTING=1, JOINED=2
		if "session_mode" in gm:
			match int(gm.session_mode):
				0: info["session_mode"] = "SINGLE_PLAYER"
				1: info["session_mode"] = "HOSTING"
				2: info["session_mode"] = "JOINED"
				_: info["session_mode"] = str(gm.session_mode)
		
		if "world_seed" in gm:
			info["world_seed"] = gm.world_seed
		if "current_profile_id" in gm:
			info["profile_id"] = gm.current_profile_id
	
	# Try TimeManager
	if has_node("/root/TimeManager"):
		var tm = get_node("/root/TimeManager")
		# Support both LOOP's naming (current_hour, current_day) and generic (hour, day)
		var day_val: int = tm.current_day if "current_day" in tm else (tm.day if "day" in tm else 1)
		var hour_val: int = tm.current_hour if "current_hour" in tm else (tm.hour if "hour" in tm else 6)
		var minute_val: int = tm.get_current_minute() if tm.has_method("get_current_minute") else (tm.minute if "minute" in tm else 0)
		var season_val: int = tm.current_season if "current_season" in tm else (tm.season if "season" in tm else 0)
		
		info["time"] = {
			"day": day_val,
			"hour": hour_val,
			"minute": minute_val,
			"season": _season_int_to_name(season_val),
			"year": tm.year if "year" in tm else 1,
			"is_night": tm.is_night if "is_night" in tm else (tm.is_night() if tm.has_method("is_night") else false),
			"paused": tm.is_paused() if tm.has_method("is_paused") else (tm.paused if "paused" in tm else false),
			"time_scale": tm.time_scale if "time_scale" in tm else 1.0,
			"seconds_into_day": tm._seconds_into_day if "_seconds_into_day" in tm else (tm.seconds_into_day if "seconds_into_day" in tm else 0.0)
		}
	
	return info


func _season_int_to_name(season: int) -> String:
	match season:
		0: return "SPRING"
		1: return "SUMMER"
		2: return "AUTUMN"
		3: return "WINTER"
		_: return str(season)


func _get_ui_info() -> Dictionary:
	var open_panels := []
	var ui_root := get_tree().current_scene.get_node_or_null("UI") if get_tree().current_scene else null
	
	if ui_root:
		for child in ui_root.get_children():
			if child is Control and child.visible:
				open_panels.append(child.name)
	
	return {"open_panels": open_panels}


func _find_player() -> Node:
	var current := get_tree().current_scene
	if not current:
		return null
	
	# Try common player paths
	for path in ["Players/1", "Player", "Players/Player"]:
		var player := current.get_node_or_null(path)
		if player:
			return player
	
	# Search by group
	var players := get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		return players[0]
	
	return null


func _get_player_info(player: Node) -> Dictionary:
	# Prefer playtest hook if available
	if player.has_method("_playtest_get_state"):
		var state: Dictionary = player._playtest_get_state()
		state["exists"] = true
		return state
	
	# Fallback to generic property inspection
	var info := {
		"exists": true,
		"name": player.name,
		"position": {"x": 0.0, "y": 0.0},
		"tile_position": {"x": 0, "y": 0},
		"facing": "down",
		"state": "idle",
		"health": 100.0,
		"max_health": 100.0,
		"hunger": 100.0,
		"max_hunger": 100.0,
		"energy": 100.0,
		"max_energy": 100.0,
		"money": 0,
		"is_running": false,
		"is_flying": false,
		"sleeping": false
	}
	
	if "global_position" in player:
		info["position"] = {"x": player.global_position.x, "y": player.global_position.y}
	if "tile_position" in player:
		info["tile_position"] = {"x": player.tile_position.x, "y": player.tile_position.y}
	if "facing_direction" in player:
		info["facing"] = str(player.facing_direction).to_lower()
	if "current_state" in player:
		info["state"] = str(player.current_state).to_lower()
	if "health" in player:
		info["health"] = player.health
	if "max_health" in player:
		info["max_health"] = player.max_health
	if "hunger" in player:
		info["hunger"] = player.hunger
	if "max_hunger" in player:
		info["max_hunger"] = player.max_hunger
	if "energy" in player:
		info["energy"] = player.energy
	if "max_energy" in player:
		info["max_energy"] = player.max_energy
	if "money" in player:
		info["money"] = player.money
	if "is_running" in player:
		info["is_running"] = player.is_running
	if "is_flying" in player:
		info["is_flying"] = player.is_flying
	if "sleeping" in player:
		info["sleeping"] = player.sleeping
	
	return info


func _get_camera_info() -> Dictionary:
	var camera := get_viewport().get_camera_2d()
	if not camera:
		return {}
	
	return {
		"position": {"x": camera.global_position.x, "y": camera.global_position.y},
		"zoom": {"x": camera.zoom.x, "y": camera.zoom.y}
	}


func _get_npcs_info() -> Array:
	var npcs := []
	for npc in get_tree().get_nodes_in_group("npc"):
		npcs.append(_get_npc_info(npc))
	return npcs


func _get_npc_info(npc: Node) -> Dictionary:
	# Prefer playtest hook if available
	if npc.has_method("_playtest_get_state"):
		var state: Dictionary = npc._playtest_get_state()
		state["_node_id"] = npc.get_instance_id()
		state["_node_path"] = str(npc.get_path())
		return state
	
	# Fallback to generic property inspection
	var info := {
		"name": npc.name,
		"_node_id": npc.get_instance_id(),
		"_node_path": str(npc.get_path())
	}
	
	if "global_position" in npc:
		info["position"] = {"x": npc.global_position.x, "y": npc.global_position.y}
	
	# NPC-specific attributes for LOOP
	if "npc_name" in npc:
		info["display_name"] = npc.npc_name
	if "relationship" in npc:
		info["relationship"] = npc.relationship
	if "friendship_level" in npc:
		info["friendship_level"] = npc.friendship_level
	if "mood" in npc:
		info["mood"] = str(npc.mood)
	if "current_activity" in npc:
		info["activity"] = str(npc.current_activity)
	if "schedule" in npc:
		info["schedule"] = str(npc.schedule)
	
	# Dialogue state
	if "dialogue_flags" in npc:
		info["dialogue_flags"] = npc.dialogue_flags
	if "quest_state" in npc:
		info["quest_state"] = npc.quest_state
	if "has_quest" in npc:
		info["has_quest"] = npc.has_quest
	if "gifts_today" in npc:
		info["gifts_today"] = npc.gifts_today
	if "gifts_this_week" in npc:
		info["gifts_this_week"] = npc.gifts_this_week
	
	# LLM NPC specific
	if "memory" in npc and npc.memory is Array:
		info["memory_count"] = npc.memory.size()
	if "personality" in npc:
		info["personality"] = npc.personality
	
	return info


# =============================================================================
# Input Simulation (Inspired by GodotTestDriver patterns)
# =============================================================================

func _send_input(params: Dictionary) -> Dictionary:
	var action: String = params.get("action", "")
	if action.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'action' parameter"}}
	
	if not InputMap.has_action(action):
		return {"error": {"code": -32602, "message": "Unknown action: " + action}}
	
	var duration_ms: int = params.get("duration_ms", 100)
	var strength: float = params.get("strength", 1.0)
	
	# Record if active
	if _recording:
		_recorded_inputs.append({
			"type": "action",
			"action": action,
			"duration_ms": duration_ms,
			"strength": strength,
			"timestamp_ms": Time.get_ticks_msec() - _recording_start_ms
		})
	
	# Use InputEventAction for proper event propagation (GodotTestDriver pattern)
	_start_action(action, strength)
	
	# Schedule release after duration
	if duration_ms > 0:
		get_tree().create_timer(duration_ms / 1000.0).timeout.connect(
			func(): _end_action(action)
		)
	else:
		call_deferred("_end_action", action)
	
	return {"success": true, "action": action, "duration_ms": duration_ms, "strength": strength}


func _hold_action(params: Dictionary) -> Dictionary:
	var action: String = params.get("action", "")
	if action.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'action' parameter"}}
	
	if not InputMap.has_action(action):
		return {"error": {"code": -32602, "message": "Unknown action: " + action}}
	
	var strength: float = params.get("strength", 1.0)
	
	if _recording:
		_recorded_inputs.append({
			"type": "hold",
			"action": action,
			"strength": strength,
			"timestamp_ms": Time.get_ticks_msec() - _recording_start_ms
		})
	
	_start_action(action, strength)
	_held_actions[action] = -1
	
	return {"success": true, "action": action, "held": true}


func _release_action(params: Dictionary) -> Dictionary:
	var action: String = params.get("action", "")
	if action.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'action' parameter"}}
	
	if _recording:
		_recorded_inputs.append({
			"type": "release",
			"action": action,
			"timestamp_ms": Time.get_ticks_msec() - _recording_start_ms
		})
	
	_end_action(action)
	_held_actions.erase(action)
	
	return {"success": true, "action": action, "released": true}


func _start_action(action: String, strength: float = 1.0) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	event.strength = strength
	Input.parse_input_event(event)
	Input.action_press(action, strength)
	Input.flush_buffered_events()


func _end_action(action: String) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = false
	Input.parse_input_event(event)
	Input.action_release(action)
	Input.flush_buffered_events()


func _process_held_actions() -> void:
	var now := Time.get_ticks_msec()
	var to_release: Array[String] = []
	
	for action in _held_actions:
		var release_time: int = _held_actions[action]
		if release_time > 0 and now >= release_time:
			to_release.append(action)
	
	for action in to_release:
		_end_action(action)
		_held_actions.erase(action)


func _click_at(params: Dictionary) -> Dictionary:
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var button: int = params.get("button", MOUSE_BUTTON_LEFT)
	
	if _recording:
		_recorded_inputs.append({
			"type": "click",
			"x": x, "y": y,
			"button": button,
			"timestamp_ms": Time.get_ticks_msec() - _recording_start_ms
		})
	
	var position := Vector2(x, y)
	var viewport := get_viewport()
	
	_move_mouse_to(viewport, position)
	
	var press_event := InputEventMouseButton.new()
	press_event.button_index = button
	press_event.pressed = true
	press_event.position = position
	press_event.global_position = position
	Input.parse_input_event(press_event)
	Input.flush_buffered_events()
	
	call_deferred("_release_mouse", position, button)
	
	return {"success": true, "position": {"x": x, "y": y}, "button": button}


func _release_mouse(position: Vector2, button: int) -> void:
	var release_event := InputEventMouseButton.new()
	release_event.button_index = button
	release_event.pressed = false
	release_event.position = position
	release_event.global_position = position
	Input.parse_input_event(release_event)
	Input.flush_buffered_events()


func _move_mouse(params: Dictionary) -> Dictionary:
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	
	_move_mouse_to(get_viewport(), Vector2(x, y))
	
	return {"success": true, "position": {"x": x, "y": y}}


func _move_mouse_to(viewport: Viewport, position: Vector2) -> void:
	var old_position := viewport.get_mouse_position()
	viewport.warp_mouse(position)
	
	var motion_event := InputEventMouseMotion.new()
	motion_event.position = position
	motion_event.global_position = position
	motion_event.relative = position - old_position
	Input.parse_input_event(motion_event)
	Input.flush_buffered_events()


# =============================================================================
# Time Control
# =============================================================================

func _time_advance(params: Dictionary) -> Dictionary:
	var tm := get_node_or_null("/root/TimeManager")
	if not tm:
		return {"error": {"code": -32603, "message": "TimeManager not found"}}
	
	var days: int = params.get("days", 0)
	var hours: int = params.get("hours", 0)
	var minutes: int = params.get("minutes", 0)
	
	# Calculate total hours to advance
	var total_hours: int = hours + (days * 24) + (minutes / 60)
	var remaining_minutes: int = minutes % 60
	
	if total_hours <= 0 and remaining_minutes <= 0:
		return {"error": {"code": -32602, "message": "Must advance by at least 1 minute"}}
	
	# Get current time
	var current_day: int = tm.current_day if "current_day" in tm else (tm.day if "day" in tm else 1)
	var current_hour: int = tm.current_hour if "current_hour" in tm else (tm.hour if "hour" in tm else 6)
	
	# Calculate new time
	var new_hour: int = current_hour + total_hours
	var extra_days: int = new_hour / 24
	new_hour = new_hour % 24
	var new_day: int = current_day + extra_days
	
	# Try set_time method first (LOOP's TimeManager has this)
	if tm.has_method("set_time"):
		tm.set_time(new_day, new_hour)
	elif tm.has_method("advance_time"):
		tm.advance_time(total_hours * 60 + remaining_minutes)
	elif tm.has_method("skip_time"):
		tm.skip_time(total_hours * 60 + remaining_minutes)
	else:
		# Manual property setting
		if "current_day" in tm:
			tm.current_day = new_day
		elif "day" in tm:
			tm.day = new_day
		
		if "current_hour" in tm:
			tm.current_hour = new_hour
		elif "hour" in tm:
			tm.hour = new_hour
	
	return {
		"success": true,
		"advanced": {"days": days, "hours": hours, "minutes": minutes},
		"current_time": _get_world_info()["time"]
	}


func _time_set(params: Dictionary) -> Dictionary:
	var tm := get_node_or_null("/root/TimeManager")
	if not tm:
		return {"error": {"code": -32603, "message": "TimeManager not found"}}
	
	if "day" in params and "day" in tm:
		tm.day = params["day"]
	if "hour" in params and "hour" in tm:
		tm.hour = params["hour"]
	if "minute" in params and "minute" in tm:
		tm.minute = params["minute"]
	if "season" in params and "season" in tm:
		var season_str: String = params["season"].to_upper()
		match season_str:
			"SPRING": tm.season = 0
			"SUMMER": tm.season = 1
			"AUTUMN", "FALL": tm.season = 2
			"WINTER": tm.season = 3
	if "year" in params and "year" in tm:
		tm.year = params["year"]
	
	return {"success": true, "current_time": _get_world_info()["time"]}


func _time_pause(params: Dictionary) -> Dictionary:
	var tm := get_node_or_null("/root/TimeManager")
	if not tm:
		return {"error": {"code": -32603, "message": "TimeManager not found"}}
	
	if tm.has_method("pause"):
		tm.pause()
	elif "paused" in tm:
		tm.paused = true
	else:
		return {"error": {"code": -32603, "message": "TimeManager doesn't support pausing"}}
	
	return {"success": true, "paused": true}


func _time_resume(params: Dictionary) -> Dictionary:
	var tm := get_node_or_null("/root/TimeManager")
	if not tm:
		return {"error": {"code": -32603, "message": "TimeManager not found"}}
	
	if tm.has_method("resume"):
		tm.resume()
	elif "paused" in tm:
		tm.paused = false
	else:
		return {"error": {"code": -32603, "message": "TimeManager doesn't support resuming"}}
	
	return {"success": true, "paused": false}


# =============================================================================
# NPC State
# =============================================================================

func _get_npc(params: Dictionary) -> Dictionary:
	var npc_name: String = params.get("name", "")
	if npc_name.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'name' parameter"}}
	
	for npc in get_tree().get_nodes_in_group("npc"):
		var name_match := false
		if npc.name.to_lower() == npc_name.to_lower():
			name_match = true
		elif "npc_name" in npc and npc.npc_name.to_lower() == npc_name.to_lower():
			name_match = true
		elif "display_name" in npc and npc.display_name.to_lower() == npc_name.to_lower():
			name_match = true
		
		if name_match:
			return {"found": true, "npc": _get_npc_info(npc)}
	
	return {"found": false, "name": npc_name}


func _get_all_npcs(params: Dictionary) -> Dictionary:
	var npcs := []
	for npc in get_tree().get_nodes_in_group("npc"):
		npcs.append(_get_npc_info(npc))
	return {"npcs": npcs, "count": npcs.size()}


# =============================================================================
# Inventory
# =============================================================================

func _get_inventory(params: Dictionary) -> Dictionary:
	var player := _find_player()
	if not player:
		return {"error": {"code": -32603, "message": "Player not found"}}
	
	var inventory := {"items": [], "capacity": 0, "used": 0}
	
	# Try getting inventory via Main scene (LOOP pattern)
	var main := get_tree().current_scene
	if main and main.has_method("get_player_inventory"):
		var peer_id: int = 1
		if player.has_method("get_network_peer_id"):
			peer_id = player.get_network_peer_id()
		var inv_mgr: Node = main.get_player_inventory(peer_id)
		
		if inv_mgr:
			if inv_mgr.has_method("get_total_slot_count"):
				inventory["capacity"] = inv_mgr.get_total_slot_count()
			
			if inv_mgr.has_method("get_hotbar_items"):
				var hotbar_items = inv_mgr.get_hotbar_items()
				for item_data in hotbar_items:
					if item_data and item_data.get("id", &"") != &"":
						inventory["items"].append({
							"id": str(item_data.get("id", "")),
							"name": item_data.get("display_name", str(item_data.get("id", "unknown"))),
							"quantity": item_data.get("count", 1),
							"slot_type": "hotbar",
						})
			
			# Try to get main inventory items
			if "main" in inv_mgr:
				for slot in inv_mgr.main:
					if slot and slot.item:
						inventory["items"].append({
							"id": str(slot.item.id),
							"name": slot.item.display_name if "display_name" in slot.item else str(slot.item.id),
							"quantity": slot.count,
							"slot_type": "main",
						})
			
			# Try get_material_counts for a summary
			if inv_mgr.has_method("get_material_counts"):
				var counts: Dictionary = inv_mgr.get_material_counts()
				inventory["material_counts"] = {}
				for mat_id in counts:
					inventory["material_counts"][str(mat_id)] = counts[mat_id]
			
			inventory["used"] = inventory["items"].size()
			return inventory
	
	# Fallback: Try common inventory patterns on player
	var inv_node: Node = null
	if "inventory" in player:
		inv_node = player.inventory
	elif player.has_node("Inventory"):
		inv_node = player.get_node("Inventory")
	
	if inv_node:
		if "items" in inv_node:
			for item in inv_node.items:
				if item != null:
					inventory["items"].append(_serialize_item(item))
		if "capacity" in inv_node:
			inventory["capacity"] = inv_node.capacity
		if "slots" in inv_node:
			inventory["capacity"] = inv_node.slots.size() if inv_node.slots is Array else inv_node.slots
	
	# Try InventoryManager autoload
	var inv_mgr_global := get_node_or_null("/root/InventoryManager")
	if inv_mgr_global:
		if inv_mgr_global.has_method("get_items"):
			var items = inv_mgr_global.get_items()
			for item in items:
				inventory["items"].append(_serialize_item(item))
		if inv_mgr_global.has_method("get_capacity"):
			inventory["capacity"] = inv_mgr_global.get_capacity()
	
	inventory["used"] = inventory["items"].size()
	return inventory


func _serialize_item(item: Variant) -> Dictionary:
	if item is Dictionary:
		return item
	
	var info := {"name": "", "quantity": 1, "type": "unknown"}
	
	if item is Node:
		info["name"] = item.name
		if "item_name" in item:
			info["name"] = item.item_name
		if "quantity" in item:
			info["quantity"] = item.quantity
		if "stack_size" in item:
			info["quantity"] = item.stack_size
		if "item_type" in item:
			info["type"] = str(item.item_type)
		if "category" in item:
			info["type"] = str(item.category)
	elif item is Resource:
		if "name" in item:
			info["name"] = item.name
		if "resource_name" in item:
			info["name"] = item.resource_name
	
	return info


func _add_item(params: Dictionary) -> Dictionary:
	var item_id: String = params.get("item", params.get("item_id", ""))
	var quantity: int = params.get("quantity", 1)
	
	if item_id.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'item' parameter"}}
	
	# Normalize item_id to StringName format
	var item_sn := StringName(item_id)
	
	# Get player inventory via Main scene
	var main := get_tree().current_scene
	var player := _find_player()
	var inventory: Node = null
	
	if main and main.has_method("get_player_inventory") and player:
		var peer_id: int = 1  # Single player default
		if player.has_method("get_network_peer_id"):
			peer_id = player.get_network_peer_id()
		inventory = main.get_player_inventory(peer_id)
	
	if not inventory:
		return {"error": {"code": -32603, "message": "No inventory system found"}}
	
	# Try to get definition from ContentLoader materials registry
	var content_loader := get_node_or_null("/root/ContentLoader")
	var definition: Resource = null
	
	if content_loader:
		var materials: Dictionary = content_loader.get_registry(&"materials")
		if materials.has(item_id) or materials.has(item_sn):
			# Create ResourceDefinition from material data
			var mat_data: Dictionary = materials.get(item_id, materials.get(item_sn, {}))
			var ResourceDef = load("res://scripts/resources/resource_definition.gd")
			definition = ResourceDef.new()
			definition.id = item_sn
			definition.display_name = mat_data.get("display_name", item_id.replace("_", " ").capitalize())
			definition.stack_size = mat_data.get("stack_size", 999)
			definition.discovered = true
	
	# Fallback: create a basic definition
	if not definition:
		var ResourceDef = load("res://scripts/resources/resource_definition.gd")
		if ResourceDef:
			definition = ResourceDef.new()
			definition.id = item_sn
			definition.display_name = item_id.replace("_", " ").capitalize()
			definition.stack_size = 999
			definition.discovered = true
		else:
			return {"error": {"code": -32603, "message": "Cannot create item definition"}}
	
	if inventory.has_method("add_item"):
		var remaining: int = inventory.add_item(definition, quantity)
		var added: int = quantity - remaining
		return {
			"success": added > 0,
			"item": item_id,
			"requested": quantity,
			"added": added,
			"overflow": remaining,
		}
	
	return {"error": {"code": -32603, "message": "Inventory has no add_item method"}}


func _remove_item(params: Dictionary) -> Dictionary:
	var item_id: String = params.get("item", params.get("item_id", ""))
	var quantity: int = params.get("quantity", 1)
	
	if item_id.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'item' parameter"}}
	
	# Normalize item_id
	var item_sn := StringName(item_id)
	if not item_id.contains(":"):
		item_sn = StringName("core:" + item_id)
	
	# Get player inventory via Main scene
	var main := get_tree().current_scene
	var player := _find_player()
	var inventory: Node = null
	
	if main and main.has_method("get_player_inventory") and player:
		var peer_id: int = 1
		if "get_network_peer_id" in player:
			peer_id = player.get_network_peer_id()
		inventory = main.get_player_inventory(peer_id)
	
	if inventory and inventory.has_method("remove_item_by_id"):
		var removed: int = inventory.remove_item_by_id(item_sn, quantity)
		if removed == 0:
			# Try without prefix
			removed = inventory.remove_item_by_id(StringName(item_id), quantity)
		return {
			"success": removed > 0,
			"item": item_id,
			"requested": quantity,
			"removed": removed,
		}
	
	# Fallback
	var inv_mgr := get_node_or_null("/root/InventoryManager")
	if inv_mgr and inv_mgr.has_method("remove_item_by_id"):
		var removed = inv_mgr.remove_item_by_id(item_sn, quantity)
		return {"success": removed > 0, "item": item_id, "removed": removed}
	
	return {"error": {"code": -32603, "message": "No inventory system found"}}


# =============================================================================
# Save/Load
# =============================================================================

func _save_game(params: Dictionary) -> Dictionary:
	var slot: String = params.get("slot", "playtest_save")
	
	var save_mgr := get_node_or_null("/root/SaveManager")
	if save_mgr:
		# Prefer playtest hook
		if save_mgr.has_method("_playtest_save"):
			return save_mgr._playtest_save(slot)
		# Fallback to standard methods
		if save_mgr.has_method("save_to_slot"):
			save_mgr.save_to_slot(slot)
			return {"success": true, "slot": slot}
		if save_mgr.has_method("save_game"):
			var result = save_mgr.save_game(slot)
			return {"success": true, "slot": slot, "result": str(result)}
		elif save_mgr.has_method("save"):
			var result = save_mgr.save(slot)
			return {"success": true, "slot": slot, "result": str(result)}
	
	# Try GameManager
	var gm := get_node_or_null("/root/GameManager")
	if gm and gm.has_method("save_game"):
		var result = gm.save_game(slot)
		return {"success": true, "slot": slot, "result": str(result)}
	
	return {"error": {"code": -32603, "message": "No save system found"}}


func _load_game(params: Dictionary) -> Dictionary:
	var slot: String = params.get("slot", "playtest_save")
	
	var save_mgr := get_node_or_null("/root/SaveManager")
	if save_mgr:
		# Prefer playtest hook
		if save_mgr.has_method("_playtest_load"):
			return save_mgr._playtest_load(slot)
		# Fallback to standard methods
		if save_mgr.has_method("load_from_slot"):
			var result = save_mgr.load_from_slot(slot)
			return {"success": not result.is_empty(), "slot": slot}
		if save_mgr.has_method("load_game"):
			var result = save_mgr.load_game(slot)
			return {"success": true, "slot": slot, "result": str(result)}
		elif save_mgr.has_method("load"):
			var result = save_mgr.load(slot)
			return {"success": true, "slot": slot, "result": str(result)}
	
	var gm := get_node_or_null("/root/GameManager")
	if gm and gm.has_method("load_game"):
		var result = gm.load_game(slot)
		return {"success": true, "slot": slot, "result": str(result)}
	
	return {"error": {"code": -32603, "message": "No save system found"}}


func _list_saves(params: Dictionary) -> Dictionary:
	var save_mgr := get_node_or_null("/root/SaveManager")
	if save_mgr:
		# Prefer playtest hook
		if save_mgr.has_method("_playtest_list_saves"):
			return save_mgr._playtest_list_saves()
		# Fallback to list_all_slots
		if save_mgr.has_method("list_all_slots"):
			var slots = save_mgr.list_all_slots()
			return {"saves": slots, "count": slots.size()}
	
	# Generic fallback: scan directory
	var saves := []
	var save_dir := "user://saves"
	
	var dir := DirAccess.open(save_dir)
	if dir:
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if not dir.current_is_dir() and (file_name.ends_with(".save") or file_name.ends_with(".json")):
				var full_path := save_dir + "/" + file_name
				saves.append({
					"name": file_name.get_basename(),
					"path": full_path,
					"modified": FileAccess.get_modified_time(full_path)
				})
			file_name = dir.get_next()
	
	return {"saves": saves, "count": saves.size()}


func _delete_save(params: Dictionary) -> Dictionary:
	var slot: String = params.get("slot", "")
	if slot.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'slot' parameter"}}
	
	var save_mgr := get_node_or_null("/root/SaveManager")
	if save_mgr:
		# Prefer playtest hook
		if save_mgr.has_method("_playtest_delete_save"):
			return save_mgr._playtest_delete_save(slot)
		# Fallback to delete_slot
		if save_mgr.has_method("delete_slot"):
			save_mgr.delete_slot(slot)
			return {"success": true, "slot": slot}
	
	# Generic fallback: delete files
	var save_dir := "user://saves"
	var deleted := false
	
	for ext in [".save", ".json", ""]:
		var path: String = save_dir + "/" + slot + ext
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
			deleted = true
	
	return {"success": deleted, "slot": slot}


# =============================================================================
# Performance Monitoring
# =============================================================================

func _get_performance(params: Dictionary) -> Dictionary:
	var fps := Engine.get_frames_per_second()
	var frame_time := 1000.0 / fps if fps > 0 else 0.0
	
	# Calculate stats from tracked frame times
	var avg_frame_ms := 0.0
	var max_frame_ms := 0.0
	var min_frame_ms := 999999.0
	
	if _frame_times.size() > 0:
		var total := 0.0
		for ft in _frame_times:
			total += ft
			max_frame_ms = maxf(max_frame_ms, ft)
			min_frame_ms = minf(min_frame_ms, ft)
		avg_frame_ms = total / _frame_times.size()
	
	# Memory info
	var static_mem := OS.get_static_memory_usage()
	var peak_mem := OS.get_static_memory_peak_usage() if OS.has_method("get_static_memory_peak_usage") else 0
	
	# Object counts
	var orphan_nodes := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	var total_objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var resource_count := Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
	
	# Rendering
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var vertices := Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	
	return {
		"fps": fps,
		"frame_time_ms": frame_time,
		"avg_frame_ms": avg_frame_ms,
		"max_frame_ms": max_frame_ms,
		"min_frame_ms": min_frame_ms if min_frame_ms < 999999.0 else 0.0,
		"memory": {
			"static_mb": static_mem / 1048576.0,
			"peak_mb": peak_mem / 1048576.0
		},
		"objects": {
			"total": int(total_objects),
			"orphan_nodes": int(orphan_nodes),
			"resources": int(resource_count)
		},
		"rendering": {
			"draw_calls": int(draw_calls),
			"vertices": int(vertices)
		},
		"samples": _frame_times.size()
	}


func _assert_performance(params: Dictionary) -> Dictionary:
	var perf := _get_performance({})
	var failures := []
	
	if "min_fps" in params:
		var min_fps: float = params["min_fps"]
		if perf["fps"] < min_fps:
			failures.append("FPS %.1f < required %.1f" % [perf["fps"], min_fps])
	
	if "max_frame_ms" in params:
		var max_frame: float = params["max_frame_ms"]
		if perf["max_frame_ms"] > max_frame:
			failures.append("Max frame %.1fms > allowed %.1fms" % [perf["max_frame_ms"], max_frame])
	
	if "max_avg_frame_ms" in params:
		var max_avg: float = params["max_avg_frame_ms"]
		if perf["avg_frame_ms"] > max_avg:
			failures.append("Avg frame %.1fms > allowed %.1fms" % [perf["avg_frame_ms"], max_avg])
	
	if "max_memory_mb" in params:
		var max_mem: float = params["max_memory_mb"]
		if perf["memory"]["static_mb"] > max_mem:
			failures.append("Memory %.1fMB > allowed %.1fMB" % [perf["memory"]["static_mb"], max_mem])
	
	if "max_orphan_nodes" in params:
		var max_orphans: int = params["max_orphan_nodes"]
		if perf["objects"]["orphan_nodes"] > max_orphans:
			failures.append("Orphan nodes %d > allowed %d" % [perf["objects"]["orphan_nodes"], max_orphans])
	
	return {
		"success": failures.size() == 0,
		"failures": failures,
		"performance": perf
	}


# =============================================================================
# Error Capture
# =============================================================================

func _start_error_capture(params: Dictionary) -> Dictionary:
	_captured_errors.clear()
	_capture_errors = true
	
	# Hook into Godot's error handling
	if not is_connected("tree_entered", _on_tree_error):
		# Note: Godot doesn't have a direct error signal, so we check the log
		pass
	
	return {"success": true, "capturing": true}


func _stop_error_capture(params: Dictionary) -> Dictionary:
	_capture_errors = false
	return {"success": true, "capturing": false, "error_count": _captured_errors.size()}


func _get_captured_errors(params: Dictionary) -> Dictionary:
	return {
		"errors": _captured_errors,
		"count": _captured_errors.size(),
		"capturing": _capture_errors
	}


func _on_tree_error() -> void:
	# Placeholder - Godot doesn't emit errors as signals
	pass


# For error capture, we'll check the CrashHandler if available
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _capture_errors:
		# Try to capture any crash info
		var crash_handler := get_node_or_null("/root/CrashHandler")
		if crash_handler and "last_error" in crash_handler:
			_captured_errors.append({
				"type": "crash",
				"message": crash_handler.last_error,
				"timestamp_ms": Time.get_ticks_msec()
			})


# =============================================================================
# Recording & Playback
# =============================================================================

func _start_recording(params: Dictionary) -> Dictionary:
	_recording = true
	_recorded_inputs.clear()
	_recording_start_ms = Time.get_ticks_msec()
	
	return {"success": true, "recording": true}


func _stop_recording(params: Dictionary) -> Dictionary:
	_recording = false
	var duration_ms := Time.get_ticks_msec() - _recording_start_ms
	
	var save_path: String = params.get("save_to", "")
	if not save_path.is_empty():
		var file := FileAccess.open(save_path, FileAccess.WRITE)
		if file:
			file.store_string(JSON.stringify({
				"version": VERSION,
				"duration_ms": duration_ms,
				"inputs": _recorded_inputs
			}, "\t"))
			file.close()
	
	return {
		"success": true,
		"recording": false,
		"duration_ms": duration_ms,
		"input_count": _recorded_inputs.size(),
		"inputs": _recorded_inputs if save_path.is_empty() else null,
		"saved_to": save_path if not save_path.is_empty() else null
	}


func _playback(params: Dictionary) -> Dictionary:
	var inputs: Array = params.get("inputs", [])
	var load_from: String = params.get("load_from", "")
	
	if not load_from.is_empty():
		var file := FileAccess.open(load_from, FileAccess.READ)
		if file:
			var json := JSON.new()
			if json.parse(file.get_as_text()) == OK:
				var data: Dictionary = json.data
				inputs = data.get("inputs", [])
			file.close()
	
	if inputs.is_empty():
		return {"error": {"code": -32602, "message": "No inputs to play back"}}
	
	# Schedule all inputs based on their timestamps
	for input_event in inputs:
		var delay_ms: int = input_event.get("timestamp_ms", 0)
		get_tree().create_timer(delay_ms / 1000.0).timeout.connect(
			func(): _replay_input(input_event)
		)
	
	return {"success": true, "input_count": inputs.size()}


func _replay_input(input_event: Dictionary) -> void:
	match input_event.get("type", ""):
		"action":
			_send_input({
				"action": input_event.get("action", ""),
				"duration_ms": input_event.get("duration_ms", 100),
				"strength": input_event.get("strength", 1.0)
			})
		"hold":
			_hold_action({
				"action": input_event.get("action", ""),
				"strength": input_event.get("strength", 1.0)
			})
		"release":
			_release_action({"action": input_event.get("action", "")})
		"click":
			_click_at({
				"x": input_event.get("x", 0.0),
				"y": input_event.get("y", 0.0),
				"button": input_event.get("button", MOUSE_BUTTON_LEFT)
			})


# =============================================================================
# Visual Regression
# =============================================================================

func _screenshot(params: Dictionary) -> Dictionary:
	var scale: float = params.get("scale", 1.0)
	var format: String = params.get("format", "png")
	var name: String = params.get("name", "")
	
	var viewport := get_viewport()
	var img := viewport.get_texture().get_image()
	
	if scale != 1.0:
		var new_size := Vector2i(int(img.get_width() * scale), int(img.get_height() * scale))
		img.resize(new_size.x, new_size.y, Image.INTERPOLATE_LANCZOS)
	
	var timestamp := Time.get_ticks_msec()
	var filename := name if not name.is_empty() else "playtest_%d" % timestamp
	filename += "." + format
	
	var dir_path := "user://screenshots"
	var full_path := dir_path + "/" + filename
	
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
	
	var err: int
	if format == "jpg" or format == "jpeg":
		err = img.save_jpg(full_path)
	else:
		err = img.save_png(full_path)
	
	if err != OK:
		return {"error": {"code": -32603, "message": "Failed to save screenshot: " + error_string(err)}}
	
	var global_path := ProjectSettings.globalize_path(full_path)
	return {
		"success": true,
		"path": global_path,
		"size": {"width": img.get_width(), "height": img.get_height()}
	}


func _save_baseline(params: Dictionary) -> Dictionary:
	var name: String = params.get("name", "")
	if name.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'name' parameter"}}
	
	var viewport := get_viewport()
	var img := viewport.get_texture().get_image()
	
	var path := _baselines_dir + "/" + name + ".png"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_baselines_dir))
	
	var err := img.save_png(path)
	if err != OK:
		return {"error": {"code": -32603, "message": "Failed to save baseline: " + error_string(err)}}
	
	return {
		"success": true,
		"path": ProjectSettings.globalize_path(path),
		"size": {"width": img.get_width(), "height": img.get_height()}
	}


func _compare_screenshot(params: Dictionary) -> Dictionary:
	var name: String = params.get("name", "")
	var threshold: float = params.get("threshold", 0.01)  # 1% pixel difference allowed
	
	if name.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'name' parameter"}}
	
	var baseline_path := _baselines_dir + "/" + name + ".png"
	if not FileAccess.file_exists(baseline_path):
		return {"error": {"code": -32602, "message": "Baseline not found: " + name}}
	
	# Load baseline
	var baseline := Image.load_from_file(baseline_path)
	if not baseline:
		return {"error": {"code": -32603, "message": "Failed to load baseline"}}
	
	# Capture current
	var current := get_viewport().get_texture().get_image()
	
	# Compare dimensions
	if baseline.get_width() != current.get_width() or baseline.get_height() != current.get_height():
		return {
			"success": false,
			"match": false,
			"reason": "Size mismatch: baseline %dx%d vs current %dx%d" % [
				baseline.get_width(), baseline.get_height(),
				current.get_width(), current.get_height()
			]
		}
	
	# Compare pixels
	var total_pixels := baseline.get_width() * baseline.get_height()
	var different_pixels := 0
	
	for y in range(baseline.get_height()):
		for x in range(baseline.get_width()):
			var baseline_pixel := baseline.get_pixel(x, y)
			var current_pixel := current.get_pixel(x, y)
			
			# Compare with small tolerance for compression artifacts
			if absf(baseline_pixel.r - current_pixel.r) > 0.02 or \
			   absf(baseline_pixel.g - current_pixel.g) > 0.02 or \
			   absf(baseline_pixel.b - current_pixel.b) > 0.02 or \
			   absf(baseline_pixel.a - current_pixel.a) > 0.02:
				different_pixels += 1
	
	var diff_ratio := float(different_pixels) / float(total_pixels)
	var matches := diff_ratio <= threshold
	
	# Save diff image if there are differences
	var diff_path := ""
	if not matches:
		var diff_img := Image.create(baseline.get_width(), baseline.get_height(), false, Image.FORMAT_RGBA8)
		for y in range(baseline.get_height()):
			for x in range(baseline.get_width()):
				var baseline_pixel := baseline.get_pixel(x, y)
				var current_pixel := current.get_pixel(x, y)
				
				if absf(baseline_pixel.r - current_pixel.r) > 0.02 or \
				   absf(baseline_pixel.g - current_pixel.g) > 0.02 or \
				   absf(baseline_pixel.b - current_pixel.b) > 0.02:
					diff_img.set_pixel(x, y, Color.RED)
				else:
					diff_img.set_pixel(x, y, current_pixel * 0.5)
		
		diff_path = "user://screenshots/diff_%s_%d.png" % [name, Time.get_ticks_msec()]
		diff_img.save_png(diff_path)
		diff_path = ProjectSettings.globalize_path(diff_path)
	
	return {
		"success": true,
		"match": matches,
		"difference_ratio": diff_ratio,
		"different_pixels": different_pixels,
		"total_pixels": total_pixels,
		"threshold": threshold,
		"diff_image": diff_path if not diff_path.is_empty() else null
	}


# =============================================================================
# Wait Conditions
# =============================================================================

func _wait_for(params: Dictionary) -> Dictionary:
	var condition: String = params.get("condition", "")
	var timeout_ms: int = params.get("timeout_ms", 5000)
	
	if condition.is_empty():
		return {"current_time_ms": Time.get_ticks_msec(), "timeout_ms": timeout_ms}
	
	var result := _evaluate_condition(condition)
	return {
		"condition": condition,
		"met": result,
		"current_time_ms": Time.get_ticks_msec()
	}


func _evaluate_condition(condition: String) -> bool:
	var state := _get_state({})
	
	var parts := condition.split(" ")
	if parts.size() < 3:
		return false
	
	var left_path := parts[0]
	var operator := parts[1]
	var right_value := " ".join(parts.slice(2))
	
	var left_val = _get_nested_value(state, left_path)
	if left_val == null:
		return false
	
	var right_val: Variant = right_value
	if right_value.begins_with("'") and right_value.ends_with("'"):
		right_val = right_value.substr(1, right_value.length() - 2)
	elif right_value.is_valid_float():
		right_val = float(right_value)
	elif right_value == "true":
		right_val = true
	elif right_value == "false":
		right_val = false
	
	match operator:
		"==":
			return left_val == right_val
		"!=":
			return left_val != right_val
		">":
			return float(left_val) > float(right_val)
		"<":
			return float(left_val) < float(right_val)
		">=":
			return float(left_val) >= float(right_val)
		"<=":
			return float(left_val) <= float(right_val)
		_:
			return false


func _get_nested_value(dict: Dictionary, path: String) -> Variant:
	var parts := path.split(".")
	var current: Variant = dict
	
	for part in parts:
		if current is Dictionary and part in current:
			current = current[part]
		elif current is Array and part.is_valid_int():
			var idx := int(part)
			if idx >= 0 and idx < current.size():
				current = current[idx]
			else:
				return null
		else:
			return null
	
	return current


# =============================================================================
# Scene/Node Control
# =============================================================================

func _scene_change(params: Dictionary) -> Dictionary:
	var scene_path: String = params.get("scene", "")
	if scene_path.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'scene' parameter"}}
	
	if not ResourceLoader.exists(scene_path):
		return {"error": {"code": -32602, "message": "Scene not found: " + scene_path}}
	
	var err := get_tree().change_scene_to_file(scene_path)
	if err != OK:
		return {"error": {"code": -32603, "message": "Failed to change scene: " + error_string(err)}}
	
	return {"success": true, "scene": scene_path}


func _call_method(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node", "")
	var method_name: String = params.get("method", "")
	var args: Array = params.get("args", [])
	
	if node_path.is_empty() or method_name.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'node' or 'method' parameter"}}
	
	var node := get_node_or_null(node_path)
	if not node:
		var current := get_tree().current_scene
		if current:
			node = current.get_node_or_null(node_path.trim_prefix("/root/"))
	
	if not node:
		return {"error": {"code": -32602, "message": "Node not found: " + node_path}}
	
	if not node.has_method(method_name):
		return {"error": {"code": -32602, "message": "Method not found: " + method_name}}
	
	var result = node.callv(method_name, args)
	return {"success": true, "node": node_path, "method": method_name, "result": str(result) if result != null else null}


func _execute(params: Dictionary) -> Dictionary:
	var expression_str: String = params.get("expression", "")
	if expression_str.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'expression' parameter"}}
	
	var expression := Expression.new()
	var err := expression.parse(expression_str)
	
	if err != OK:
		return {"error": {"code": -32602, "message": "Parse error: " + expression.get_error_text()}}
	
	var result = expression.execute([], self)
	
	if expression.has_execute_failed():
		return {"error": {"code": -32603, "message": "Execution failed: " + expression.get_error_text()}}
	
	return {"success": true, "result": str(result) if result != null else null}


# =============================================================================
# Query
# =============================================================================

func _query(params: Dictionary) -> Dictionary:
	var query_type: String = params.get("type", "")
	
	match query_type:
		"node":
			return _query_node(params)
		"entities_near":
			return _query_entities_near(params)
		"tile":
			return _query_tile(params)
		"input_actions":
			return _query_input_actions()
		_:
			return {"error": {"code": -32602, "message": "Unknown query type: " + query_type}}


func _query_node(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var node := get_node_or_null(path)
	
	if not node:
		var current := get_tree().current_scene
		if current:
			node = current.get_node_or_null(path)
	
	if not node:
		return {"found": false, "path": path}
	
	var info := {
		"found": true,
		"path": str(node.get_path()),
		"name": node.name,
		"class": node.get_class(),
		"visible": true
	}
	
	if node is CanvasItem:
		info["visible"] = node.visible
	if node is Node2D:
		info["position"] = {"x": node.global_position.x, "y": node.global_position.y}
	if node is Control:
		info["rect"] = {
			"position": {"x": node.global_position.x, "y": node.global_position.y},
			"size": {"width": node.size.x, "height": node.size.y}
		}
	
	return info


func _query_entities_near(params: Dictionary) -> Dictionary:
	var pos_dict: Dictionary = params.get("position", {})
	var radius: float = params.get("radius", 100.0)
	var position := Vector2(pos_dict.get("x", 0.0), pos_dict.get("y", 0.0))
	
	var entities := []
	
	for group in ["npc", "item", "interactable", "player"]:
		for node in get_tree().get_nodes_in_group(group):
			if "global_position" in node:
				var dist := position.distance_to(node.global_position)
				if dist <= radius:
					entities.append({
						"name": node.name,
						"group": group,
						"position": {"x": node.global_position.x, "y": node.global_position.y},
						"distance": dist
					})
	
	return {"entities": entities, "count": entities.size()}


func _query_tile(params: Dictionary) -> Dictionary:
	var pos_dict: Dictionary = params.get("position", {})
	var position := Vector2i(int(pos_dict.get("x", 0)), int(pos_dict.get("y", 0)))
	
	var current := get_tree().current_scene
	if not current:
		return {"error": {"code": -32603, "message": "No current scene"}}
	
	var tilemap := current.get_node_or_null("TileMap") as TileMapLayer
	if not tilemap:
		for child in current.get_children():
			if child is TileMapLayer:
				tilemap = child
				break
	
	if not tilemap:
		return {"error": {"code": -32603, "message": "No TileMap found"}}
	
	var source_id := tilemap.get_cell_source_id(position)
	var atlas_coords := tilemap.get_cell_atlas_coords(position)
	
	return {
		"position": {"x": position.x, "y": position.y},
		"source_id": source_id,
		"atlas_coords": {"x": atlas_coords.x, "y": atlas_coords.y},
		"has_tile": source_id != -1
	}


func _query_input_actions() -> Dictionary:
	var actions := []
	for action in InputMap.get_actions():
		if not action.begins_with("ui_"):
			actions.append(action)
	return {"actions": actions}


# =============================================================================
# World/Tile Query
# =============================================================================

func _get_tile(params: Dictionary) -> Dictionary:
	var x: int = params.get("x", 0)
	var y: int = params.get("y", 0)
	var world_tile := Vector2i(x, y)
	
	# Try WorldManager for rich tile data
	var wm := get_node_or_null("/root/WorldManager")
	if wm and wm.has_method("_get_tile_context"):
		var ctx: Dictionary = wm._get_tile_context(world_tile)
		if ctx.is_empty():
			return {"tile": world_tile, "loaded": false}
		
		var chunk_data: RefCounted = ctx.get("chunk_data")
		var cell_index: int = ctx.get("cell_index", -1)
		
		var result := {
			"tile": {"x": world_tile.x, "y": world_tile.y},
			"loaded": true,
			"chunk": {"x": ctx.chunk_coord.x, "y": ctx.chunk_coord.y},
			"local": {"x": ctx.local_tile.x, "y": ctx.local_tile.y},
		}
		
		# Get ground tile info
		if chunk_data and "ground_cells" in chunk_data and cell_index >= 0:
			var ground_cells: Array = chunk_data.ground_cells
			if cell_index < ground_cells.size():
				var ground_save_id: int = ground_cells[cell_index]
				result["ground_save_id"] = ground_save_id
				# Try to resolve to definition name
				var content_loader := get_node_or_null("/root/ContentLoader")
				if content_loader and content_loader.has_method("get_definition_by_save_id"):
					var def = content_loader.get_definition_by_save_id(&"ground_tile", ground_save_id)
					if def:
						result["ground_type"] = def.id if "id" in def else str(def)
		
		# Get object/crop at tile
		if chunk_data and "object_cells" in chunk_data and cell_index >= 0:
			var object_cells: Array = chunk_data.object_cells
			if cell_index < object_cells.size():
				var obj_save_id: int = object_cells[cell_index]
				if obj_save_id > 0:
					result["object_save_id"] = obj_save_id
		
		# Check for planted crops
		if chunk_data and chunk_data.has_method("get_crop_at"):
			var crop = chunk_data.get_crop_at(ctx.local_tile)
			if crop:
				result["crop"] = {
					"id": crop.id if "id" in crop else "unknown",
					"growth_stage": crop.growth_stage if "growth_stage" in crop else 0,
					"watered": crop.watered if "watered" in crop else false,
				}
		
		# Check walkability
		if wm.has_method("is_tile_walkable"):
			result["walkable"] = wm.is_tile_walkable(world_tile)
		if wm.has_method("is_world_tile_water"):
			result["is_water"] = wm.is_world_tile_water(world_tile)
		
		return result
	
	# Fallback to basic TileMap query
	return _query_tile({"position": {"x": x, "y": y}})


func _get_tiles_in_radius(params: Dictionary) -> Dictionary:
	var center_x: int = params.get("x", 0)
	var center_y: int = params.get("y", 0)
	var radius: int = params.get("radius", 1)
	
	var tiles := []
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var tile_info := _get_tile({"x": center_x + dx, "y": center_y + dy})
			if not tile_info.has("error"):
				tiles.append(tile_info)
	
	return {"tiles": tiles, "count": tiles.size(), "center": {"x": center_x, "y": center_y}, "radius": radius}


func _get_entities_at(params: Dictionary) -> Dictionary:
	var x: int = params.get("x", 0)
	var y: int = params.get("y", 0)
	var radius: float = params.get("radius", 32.0)  # Pixel radius
	var world_pos := Vector2(x * 32.0 + 16.0, y * 32.0 + 16.0)  # Center of tile
	
	var entities := []
	
	# Find NPCs near tile
	var npcs := get_tree().get_nodes_in_group("npc")
	for npc in npcs:
		if "global_position" in npc:
			var dist: float = npc.global_position.distance_to(world_pos)
			if dist <= radius:
				entities.append({
					"type": "npc",
					"name": npc.npc_name if "npc_name" in npc else npc.name,
					"path": str(npc.get_path()),
					"distance": dist,
				})
	
	# Find items on ground
	var items := get_tree().get_nodes_in_group("item_drop")
	for item in items:
		if "global_position" in item:
			var dist: float = item.global_position.distance_to(world_pos)
			if dist <= radius:
				entities.append({
					"type": "item",
					"id": item.item_id if "item_id" in item else "unknown",
					"quantity": item.quantity if "quantity" in item else 1,
					"path": str(item.get_path()),
					"distance": dist,
				})
	
	# Find structures/buildings
	var structures := get_tree().get_nodes_in_group("structure")
	for struct in structures:
		if "global_position" in struct:
			var dist: float = struct.global_position.distance_to(world_pos)
			if dist <= radius:
				entities.append({
					"type": "structure",
					"id": struct.structure_id if "structure_id" in struct else struct.name,
					"path": str(struct.get_path()),
					"distance": dist,
				})
	
	return {"entities": entities, "count": entities.size(), "tile": {"x": x, "y": y}}


# =============================================================================
# NPC Interaction
# =============================================================================

func _interact_npc(params: Dictionary) -> Dictionary:
	var npc_name: String = params.get("name", params.get("npc", ""))
	if npc_name.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'name' parameter"}}
	
	var npc := _find_npc_by_name(npc_name)
	if not npc:
		return {"error": {"code": -32602, "message": "NPC not found: " + npc_name}}
	
	var player := _find_player()
	if not player:
		return {"error": {"code": -32603, "message": "Player not found"}}
	
	# Call NPC interact method
	if npc.has_method("interact"):
		npc.interact(player)
		return {"success": true, "npc": npc_name, "action": "interact"}
	
	return {"error": {"code": -32603, "message": "NPC has no interact method"}}


func _give_gift(params: Dictionary) -> Dictionary:
	var npc_name: String = params.get("npc", params.get("name", ""))
	var item_id: String = params.get("item", params.get("item_id", ""))
	var quantity: int = params.get("quantity", 1)
	
	if npc_name.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'npc' parameter"}}
	if item_id.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'item' parameter"}}
	
	var npc := _find_npc_by_name(npc_name)
	if not npc:
		return {"error": {"code": -32602, "message": "NPC not found: " + npc_name}}
	
	var player := _find_player()
	if not player:
		return {"error": {"code": -32603, "message": "Player not found"}}
	
	# Check if NPC has gift handling
	if npc.has_method("receive_gift"):
		var result = npc.receive_gift(player, item_id, quantity)
		return {
			"success": true,
			"npc": npc_name,
			"item": item_id,
			"quantity": quantity,
			"reaction": result if result is String else str(result),
		}
	
	# Try relationship component
	if "relationship_component" in npc and npc.relationship_component:
		var rel = npc.relationship_component
		if rel.has_method("receive_gift"):
			var result = rel.receive_gift(item_id, quantity)
			return {
				"success": true,
				"npc": npc_name,
				"item": item_id,
				"quantity": quantity,
				"reaction": str(result),
			}
	
	return {"error": {"code": -32603, "message": "NPC cannot receive gifts"}}


func _talk_to_npc(params: Dictionary) -> Dictionary:
	var npc_name: String = params.get("npc", params.get("name", ""))
	var message: String = params.get("message", "")
	
	if npc_name.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'npc' parameter"}}
	
	var npc := _find_npc_by_name(npc_name)
	if not npc:
		return {"error": {"code": -32602, "message": "NPC not found: " + npc_name}}
	
	# Try to get conversation via Main scene
	var main := get_tree().current_scene
	if main and main.has_method("open_conversation"):
		main.open_conversation(npc)
		return {"success": true, "npc": npc_name, "action": "conversation_opened"}
	
	# Fallback: direct dialogue if available
	if npc.has_method("start_dialogue"):
		npc.start_dialogue(message)
		return {"success": true, "npc": npc_name, "action": "dialogue_started"}
	
	# Try LLM response if available (sync only - async would require different handling)
	if npc.has_method("get_greeting"):
		var response = npc.get_greeting()
		return {"success": true, "npc": npc_name, "response": str(response)}
	
	return {"error": {"code": -32603, "message": "NPC has no dialogue system"}}


func _find_npc_by_name(npc_name: String) -> Node:
	var npcs := get_tree().get_nodes_in_group("npc")
	
	# Try exact match first
	for npc in npcs:
		if "npc_name" in npc and npc.npc_name == npc_name:
			return npc
		if npc.name == npc_name:
			return npc
	
	# Try case-insensitive match
	var lower_name := npc_name.to_lower()
	for npc in npcs:
		if "npc_name" in npc and npc.npc_name.to_lower() == lower_name:
			return npc
		if npc.name.to_lower() == lower_name:
			return npc
		# Also try NPC_Name format
		if npc.name.to_lower() == "npc_" + lower_name:
			return npc
	
	return null


# =============================================================================
# Teleport
# =============================================================================

func _teleport_to(params: Dictionary) -> Dictionary:
	var player := _find_player()
	if not player:
		return {"error": {"code": -32603, "message": "Player not found"}}
	
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var tile_coords: bool = params.get("tile_coords", false)
	
	var target_pos: Vector2 = Vector2(x, y)
	
	# If tile coordinates, convert to world position
	if tile_coords:
		var tile_size: int = 16  # Default tile size
		if "tile_size" in params:
			tile_size = params.tile_size
		target_pos = Vector2(x * tile_size + tile_size / 2.0, y * tile_size + tile_size / 2.0)
	
	var old_pos: Vector2 = player.global_position
	player.global_position = target_pos
	
	return {
		"success": true,
		"old_position": {"x": old_pos.x, "y": old_pos.y},
		"new_position": {"x": target_pos.x, "y": target_pos.y},
		"tile_coords": tile_coords,
	}


func _teleport_to_npc(params: Dictionary) -> Dictionary:
	var npc_name: String = params.get("npc", params.get("name", ""))
	var offset_x: float = params.get("offset_x", 32.0)
	var offset_y: float = params.get("offset_y", 0.0)
	
	if npc_name.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'npc' parameter"}}
	
	var player := _find_player()
	if not player:
		return {"error": {"code": -32603, "message": "Player not found"}}
	
	var npc := _find_npc_by_name(npc_name)
	if not npc:
		return {"error": {"code": -32602, "message": "NPC not found: " + npc_name}}
	
	var old_pos: Vector2 = player.global_position
	var target_pos: Vector2 = npc.global_position + Vector2(offset_x, offset_y)
	player.global_position = target_pos
	
	return {
		"success": true,
		"npc": npc_name,
		"npc_position": {"x": npc.global_position.x, "y": npc.global_position.y},
		"old_position": {"x": old_pos.x, "y": old_pos.y},
		"new_position": {"x": target_pos.x, "y": target_pos.y},
	}


# =============================================================================
# Weather Control
# =============================================================================

func _get_weather(_params: Dictionary) -> Dictionary:
	var main := get_tree().current_scene
	var weather_mgr: Node = null
	
	if main and "weather_manager" in main:
		weather_mgr = main.weather_manager
	
	if not weather_mgr:
		weather_mgr = get_node_or_null("/root/WeatherManager")
	
	if not weather_mgr:
		return {"error": {"code": -32603, "message": "Weather manager not found"}}
	
	var weather_type: int = weather_mgr.current_weather if "current_weather" in weather_mgr else 0
	var weather_name: String = "unknown"
	
	# Map weather enum to name
	if weather_mgr.has_method("get") and "WEATHER_NAMES" in weather_mgr:
		var names_dict: Dictionary = weather_mgr.WEATHER_NAMES
		weather_name = names_dict.get(weather_type, "unknown")
	else:
		# Fallback mapping
		match weather_type:
			0: weather_name = "clear"
			1: weather_name = "rain"
			2: weather_name = "snow"
			3: weather_name = "fog"
			4: weather_name = "storm"
			5: weather_name = "heat_wave"
	
	return {
		"weather_type": weather_type,
		"weather_name": weather_name,
		"available_types": ["clear", "rain", "snow", "fog", "storm", "heat_wave"],
	}


func _set_weather(params: Dictionary) -> Dictionary:
	var weather: Variant = params.get("weather", params.get("type", null))
	
	if weather == null:
		return {"error": {"code": -32602, "message": "Missing 'weather' parameter"}}
	
	var main := get_tree().current_scene
	var weather_mgr: Node = null
	
	if main and "weather_manager" in main:
		weather_mgr = main.weather_manager
	
	if not weather_mgr:
		weather_mgr = get_node_or_null("/root/WeatherManager")
	
	if not weather_mgr:
		return {"error": {"code": -32603, "message": "Weather manager not found"}}
	
	# Convert string to enum if needed
	var weather_type: int = -1
	if weather is int:
		weather_type = weather
	elif weather is String:
		match weather.to_lower():
			"clear": weather_type = 0
			"rain": weather_type = 1
			"snow": weather_type = 2
			"fog": weather_type = 3
			"storm": weather_type = 4
			"heat_wave", "heatwave": weather_type = 5
			_:
				return {"error": {"code": -32602, "message": "Unknown weather type: " + weather}}
	else:
		return {"error": {"code": -32602, "message": "weather must be string or int"}}
	
	if not weather_mgr.has_method("set_weather"):
		return {"error": {"code": -32603, "message": "Weather manager has no set_weather method"}}
	
	var old_weather: int = weather_mgr.current_weather if "current_weather" in weather_mgr else -1
	weather_mgr.set_weather(weather_type)
	
	# Get the weather name for response
	var weather_names := ["clear", "rain", "snow", "fog", "storm", "heat_wave"]
	var old_name: String = weather_names[old_weather] if old_weather >= 0 and old_weather < weather_names.size() else "unknown"
	var new_name: String = weather_names[weather_type] if weather_type >= 0 and weather_type < weather_names.size() else "unknown"
	
	return {
		"success": true,
		"old_weather": old_name,
		"new_weather": new_name,
		"weather_type": weather_type,
	}


# =============================================================================
# Goal/Quest System
# =============================================================================

func _get_goals(_params: Dictionary) -> Dictionary:
	var main := get_tree().current_scene
	var goal_system: Node = null
	
	if main:
		goal_system = main.get_node_or_null("GoalSystem")
	
	if not goal_system:
		goal_system = get_node_or_null("/root/GoalSystem")
	
	if not goal_system:
		return {"error": {"code": -32603, "message": "Goal system not found"}}
	
	var goals: Array[Dictionary] = []
	
	# Get goals from all NPCs
	var npcs := get_tree().get_nodes_in_group("npc")
	for npc in npcs:
		var goal_data := _extract_npc_goal(npc)
		if not goal_data.is_empty():
			var npc_name: String = npc.npc_name if "npc_name" in npc else npc.name
			goals.append({
				"npc": npc_name,
				"goal": goal_data,
			})
	
	return {
		"count": goals.size(),
		"goals": goals,
	}


func _get_npc_goal(params: Dictionary) -> Dictionary:
	var npc_name: String = params.get("npc", params.get("name", ""))
	
	if npc_name.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'npc' parameter"}}
	
	var npc := _find_npc_by_name(npc_name)
	if not npc:
		return {"error": {"code": -32602, "message": "NPC not found: " + npc_name}}
	
	var goal_data := _extract_npc_goal(npc)
	
	return {
		"npc": npc_name,
		"has_goal": not goal_data.is_empty(),
		"goal": goal_data,
	}


func _extract_npc_goal(npc: Node) -> Dictionary:
	var goal_component: Node = null
	
	if "goal_component" in npc:
		goal_component = npc.goal_component
	elif npc.has_node("GoalComponent"):
		goal_component = npc.get_node("GoalComponent")
	
	if not goal_component:
		return {}
	
	var goal_data := {}
	
	if "current_goal" in goal_component:
		var goal: Dictionary = goal_component.current_goal
		goal_data["tag"] = goal.get("tag", "")
		goal_data["description"] = goal.get("description", "")
		goal_data["target"] = goal.get("target", "")
	
	if "progress" in goal_component:
		goal_data["progress"] = goal_component.progress
	
	if "is_complete" in goal_component:
		goal_data["is_complete"] = goal_component.is_complete
	elif goal_component.has_method("is_complete"):
		goal_data["is_complete"] = goal_component.is_complete()
	
	return goal_data


func _complete_goal(params: Dictionary) -> Dictionary:
	var npc_name: String = params.get("npc", params.get("name", ""))
	
	if npc_name.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'npc' parameter"}}
	
	var npc := _find_npc_by_name(npc_name)
	if not npc:
		return {"error": {"code": -32602, "message": "NPC not found: " + npc_name}}
	
	var goal_component: Node = null
	if "goal_component" in npc:
		goal_component = npc.goal_component
	elif npc.has_node("GoalComponent"):
		goal_component = npc.get_node("GoalComponent")
	
	if not goal_component:
		return {"error": {"code": -32603, "message": "NPC has no goal component"}}
	
	# Try to complete the goal
	if goal_component.has_method("complete"):
		goal_component.complete()
		return {"success": true, "npc": npc_name, "action": "goal_completed"}
	
	# Fallback: set progress to max
	if "progress" in goal_component:
		goal_component.progress = 1.0
		return {"success": true, "npc": npc_name, "action": "progress_set_to_max"}
	
	return {"error": {"code": -32603, "message": "Cannot complete goal - no complete method"}}


# =============================================================================
# Spawning
# =============================================================================

func _spawn_item(params: Dictionary) -> Dictionary:
	var item_id: String = params.get("item", params.get("item_id", ""))
	var quantity: int = params.get("quantity", 1)
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var near_player: bool = params.get("near_player", true)
	var offset_x: float = params.get("offset_x", 32.0)
	var offset_y: float = params.get("offset_y", 0.0)
	
	if item_id.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'item' parameter"}}
	
	var spawn_pos := Vector2(x, y)
	
	if near_player:
		var player := _find_player()
		if player:
			spawn_pos = player.global_position + Vector2(offset_x, offset_y)
	
	# Try to find ItemDropFactory or similar spawner
	var main := get_tree().current_scene
	
	# Method 1: Use ResourceDrop if available
	var resource_drop_scene: PackedScene = null
	if ResourceLoader.exists("res://scenes/objects/resource_drop.tscn"):
		resource_drop_scene = load("res://scenes/objects/resource_drop.tscn")
	
	if resource_drop_scene:
		# Create ResourceDefinition
		var ResourceDef = load("res://scripts/resources/resource_definition.gd")
		var definition: Resource = null
		
		if ResourceDef:
			definition = ResourceDef.new()
			definition.id = StringName(item_id)
			definition.display_name = item_id.replace("_", " ").capitalize()
			definition.stack_size = 999
			definition.discovered = true
		
		# Spawn the drop
		var drop: Node2D = resource_drop_scene.instantiate()
		drop.global_position = spawn_pos
		
		if drop.has_method("initialize") and definition:
			drop.initialize(definition, quantity)
		elif "resource_definition" in drop:
			drop.resource_definition = definition
			if "count" in drop:
				drop.count = quantity
		
		# Add to scene
		if main:
			main.add_child(drop)
		else:
			get_tree().current_scene.add_child(drop)
		
		return {
			"success": true,
			"item": item_id,
			"quantity": quantity,
			"position": {"x": spawn_pos.x, "y": spawn_pos.y},
			"method": "resource_drop",
		}
	
	# Method 2: Try direct inventory add as fallback
	var player := _find_player()
	if player:
		var add_result := _add_item({"item": item_id, "quantity": quantity})
		if add_result.get("success", false):
			add_result["method"] = "inventory_fallback"
			add_result["note"] = "Item added to inventory (no world drop system)"
			return add_result
	
	return {"error": {"code": -32603, "message": "No item spawning system available"}}


# =============================================================================
# Enhanced Error Capture
# =============================================================================

func _capture_error(message: String, error_type: String = "error") -> void:
	if not _capture_errors:
		return
	_captured_errors.append({
		"type": error_type,
		"message": message,
		"timestamp_ms": Time.get_ticks_msec(),
		"frame": Engine.get_frames_drawn(),
	})


# Override push_error/push_warning to capture them
func _init() -> void:
	# Can't actually override built-in push_error, but we can check print output
	pass


# =============================================================================
# Cleanup
# =============================================================================

func _exit_tree() -> void:
	if _server:
		_server.stop()
		_server = null
	
	for action in _held_actions.keys():
		_end_action(action)
	_held_actions.clear()

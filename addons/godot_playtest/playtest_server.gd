extends Node
## PlaytestServer - TCP/JSON-RPC server for AI-assisted playtesting
##
## Exposes game state and controls to external tools. Only active in debug builds.
## Connect via TCP on localhost:9876 (configurable).
##
## Inspired by GodotTestDriver patterns for input simulation and wait conditions.

const VERSION := "0.2.0"
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


func _start_server() -> void:
	_server = TCPServer.new()
	var err := _server.listen(port, "127.0.0.1")
	
	if err != OK:
		push_error("[PlaytestServer] Failed to start on port %d: %s" % [port, error_string(err)])
		return
	
	print("[PlaytestServer] Listening on localhost:%d (v%s)" % [port, VERSION])


func _process(_delta: float) -> void:
	_accept_new_clients()
	_process_clients()
	_process_held_actions()


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

func _handle_method(client: StreamPeerTCP, method: String, params: Dictionary) -> Variant:
	match method:
		"ping":
			return {"pong": true, "version": VERSION}
		
		"get_state":
			return _get_state(params)
		
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
		
		"screenshot":
			return _screenshot(params)
		
		"query":
			return _query(params)
		
		"wait_for":
			return _wait_for(params)
		
		"scene_change":
			return _scene_change(params)
		
		"call_method":
			return _call_method(params)
		
		"execute":
			if not allow_execute:
				return {"error": {"code": -32601, "message": "execute disabled"}}
			return _execute(params)
		
		_:
			return {"error": {"code": -32601, "message": "Method not found: " + method}}


# =============================================================================
# State Inspection
# =============================================================================

func _get_state(params: Dictionary) -> Dictionary:
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
		state["npcs"] = _get_npcs_info()
	
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
		info["time"] = {
			"day": tm.day if "day" in tm else 1,
			"hour": tm.hour if "hour" in tm else 6,
			"season": str(tm.season).split(":")[-1] if "season" in tm else "SPRING",
			"is_night": tm.is_night() if tm.has_method("is_night") else false,
			"paused": tm.paused if "paused" in tm else false,
			"seconds_into_day": tm.seconds_into_day if "seconds_into_day" in tm else 0.0
		}
	
	return info


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
	var info := {
		"exists": true,
		"name": player.name,
		"position": {"x": 0.0, "y": 0.0},
		"tile_position": {"x": 0, "y": 0},
		"facing": "down",
		"state": "idle",
		"health": 100.0,
		"hunger": 100.0,
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
	if "hunger" in player:
		info["hunger"] = player.hunger
	if "is_running" in player:
		info["is_running"] = player.is_running
	if "is_flying" in player:
		info["is_flying"] = player.is_flying
	if "sleeping" in player:
		info["sleeping"] = player.sleeping
	
	# Add to custom state for more details
	var custom_key := "root_%s" % player.get_path().get_concatenated_names().replace("/", "_")
	
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
		var npc_info := {
			"name": npc.name,
			"_node_id": npc.get_instance_id()
		}
		if "global_position" in npc:
			npc_info["position"] = {"x": npc.global_position.x, "y": npc.global_position.y}
		npcs.append(npc_info)
	return npcs


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
	## Hold an action indefinitely until release_action is called
	var action: String = params.get("action", "")
	if action.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'action' parameter"}}
	
	if not InputMap.has_action(action):
		return {"error": {"code": -32602, "message": "Unknown action: " + action}}
	
	var strength: float = params.get("strength", 1.0)
	_start_action(action, strength)
	_held_actions[action] = -1  # -1 = held indefinitely
	
	return {"success": true, "action": action, "held": true}


func _release_action(params: Dictionary) -> Dictionary:
	## Release a held action
	var action: String = params.get("action", "")
	if action.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'action' parameter"}}
	
	_end_action(action)
	_held_actions.erase(action)
	
	return {"success": true, "action": action, "released": true}


func _start_action(action: String, strength: float = 1.0) -> void:
	## Start an input action using proper InputEvent (GodotTestDriver pattern)
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	event.strength = strength
	Input.parse_input_event(event)
	Input.action_press(action, strength)
	Input.flush_buffered_events()


func _end_action(action: String) -> void:
	## End an input action (GodotTestDriver pattern)
	var event := InputEventAction.new()
	event.action = action
	event.pressed = false
	Input.parse_input_event(event)
	Input.action_release(action)
	Input.flush_buffered_events()


func _process_held_actions() -> void:
	## Process any held actions with timeouts
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
	## Click mouse at position (GodotTestDriver pattern)
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	var button: int = params.get("button", MOUSE_BUTTON_LEFT)
	
	var position := Vector2(x, y)
	var viewport := get_viewport()
	
	# Move mouse to position
	_move_mouse_to(viewport, position)
	
	# Press
	var press_event := InputEventMouseButton.new()
	press_event.button_index = button
	press_event.pressed = true
	press_event.position = position
	press_event.global_position = position
	Input.parse_input_event(press_event)
	Input.flush_buffered_events()
	
	# Release (next frame)
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
	## Move mouse to position
	var x: float = params.get("x", 0.0)
	var y: float = params.get("y", 0.0)
	
	_move_mouse_to(get_viewport(), Vector2(x, y))
	
	return {"success": true, "position": {"x": x, "y": y}}


func _move_mouse_to(viewport: Viewport, position: Vector2) -> void:
	## Move mouse with proper motion event (GodotTestDriver pattern)
	var old_position := viewport.get_mouse_position()
	viewport.warp_mouse(position)
	
	var motion_event := InputEventMouseMotion.new()
	motion_event.position = position
	motion_event.global_position = position
	motion_event.relative = position - old_position
	Input.parse_input_event(motion_event)
	Input.flush_buffered_events()


# =============================================================================
# Wait Conditions (Simplified - no await to avoid async complexity)
# =============================================================================

func _wait_for(params: Dictionary) -> Dictionary:
	## Check a condition or just return info about what to wait for
	## The actual waiting should be done client-side
	var condition: String = params.get("condition", "")
	var timeout_ms: int = params.get("timeout_ms", 5000)
	
	if condition.is_empty():
		# No condition, just return current time for client-side wait
		return {"current_time_ms": Time.get_ticks_msec(), "timeout_ms": timeout_ms}
	
	# Evaluate condition once and return result
	var result := _evaluate_condition(condition)
	return {
		"condition": condition,
		"met": result,
		"current_time_ms": Time.get_ticks_msec()
	}


func _evaluate_condition(condition: String) -> bool:
	## Evaluate a simple condition against current state
	## Supports: player.health > 50, scene.name == 'Main', etc.
	
	var state := _get_state({})
	
	# Parse condition (very simple parser)
	var parts := condition.split(" ")
	if parts.size() < 3:
		return false
	
	var left_path := parts[0]
	var operator := parts[1]
	var right_value := " ".join(parts.slice(2))
	
	# Get left value from state
	var left_val = _get_nested_value(state, left_path)
	if left_val == null:
		return false
	
	# Parse right value
	var right_val: Variant = right_value
	if right_value.begins_with("'") and right_value.ends_with("'"):
		right_val = right_value.substr(1, right_value.length() - 2)
	elif right_value.is_valid_float():
		right_val = float(right_value)
	elif right_value == "true":
		right_val = true
	elif right_value == "false":
		right_val = false
	
	# Compare
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
# Scene Control
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
		# Try from current scene
		var current := get_tree().current_scene
		if current:
			node = current.get_node_or_null(node_path.trim_prefix("/root/"))
	
	if not node:
		return {"error": {"code": -32602, "message": "Node not found: " + node_path}}
	
	if not node.has_method(method_name):
		return {"error": {"code": -32602, "message": "Method not found: " + method_name}}
	
	var result = node.callv(method_name, args)
	return {"success": true, "node": node_path, "method": method_name, "result": str(result) if result != null else null}


# =============================================================================
# Screenshot
# =============================================================================

func _screenshot(params: Dictionary) -> Dictionary:
	var scale: float = params.get("scale", 1.0)
	var format: String = params.get("format", "png")
	
	# Capture viewport
	var viewport := get_viewport()
	var img := viewport.get_texture().get_image()
	
	if scale != 1.0:
		var new_size := Vector2i(int(img.get_width() * scale), int(img.get_height() * scale))
		img.resize(new_size.x, new_size.y, Image.INTERPOLATE_LANCZOS)
	
	# Generate filename
	var timestamp := Time.get_ticks_msec()
	var filename := "playtest_%d.%s" % [timestamp, format]
	var dir_path := "user://screenshots"
	var full_path := dir_path + "/" + filename
	
	# Ensure directory exists
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
	
	# Save image
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
	
	# Check all physics bodies, NPCs, items, etc.
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
	
	# Try to find tilemap
	var current := get_tree().current_scene
	if not current:
		return {"error": {"code": -32603, "message": "No current scene"}}
	
	var tilemap := current.get_node_or_null("TileMap") as TileMapLayer
	if not tilemap:
		# Try finding any TileMapLayer
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
	## Return all available input actions
	var actions := []
	for action in InputMap.get_actions():
		if not action.begins_with("ui_"):  # Skip built-in UI actions
			actions.append(action)
	return {"actions": actions}


# =============================================================================
# Execute (Dangerous!)
# =============================================================================

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
# Cleanup
# =============================================================================

func _exit_tree() -> void:
	if _server:
		_server.stop()
		_server = null
	
	# Release any held actions
	for action in _held_actions.keys():
		_end_action(action)
	_held_actions.clear()

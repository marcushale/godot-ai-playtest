extends Node
## PlaytestServer - TCP/JSON-RPC server for AI-assisted playtesting (simplified)
##
## Exposes game state and controls to external tools. Only active in debug builds.
## Connect via TCP on localhost:9876 (configurable).

const VERSION := "0.1.0"
const DEFAULT_PORT := 9876
const BUFFER_SIZE := 65536

# Configuration
var port: int = DEFAULT_PORT
var enabled: bool = true

# Server state
var _server: TCPServer
var _clients: Array[StreamPeerTCP] = []
var _client_buffers: Dictionary = {}  # client -> String buffer

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
	
	print("[PlaytestServer] Listening on localhost:%d" % port)


func _process(_delta: float) -> void:
	if _server == null:
		return
	
	# Accept new connections
	while _server.is_connection_available():
		var client := _server.take_connection()
		if client:
			_clients.append(client)
			_client_buffers[client] = ""
			var client_id := client.get_instance_id()
			print("[PlaytestServer] Client connected: %d" % client_id)
			client_connected.emit(client_id)
	
	# Process existing clients
	var disconnected: Array[StreamPeerTCP] = []
	
	for client in _clients:
		if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			disconnected.append(client)
			continue
		
		client.poll()
		
		# Read available data
		var available := client.get_available_bytes()
		if available > 0:
			var data := client.get_data(mini(available, BUFFER_SIZE))
			if data[0] == OK:
				_client_buffers[client] += data[1].get_string_from_utf8()
				_process_buffer(client)
	
	# Remove disconnected clients
	for client in disconnected:
		_remove_client(client)


func _process_buffer(client: StreamPeerTCP) -> void:
	var buffer: String = _client_buffers[client]
	
	# JSON-RPC messages are newline-delimited
	while "\n" in buffer:
		var newline_pos := buffer.find("\n")
		var message := buffer.substr(0, newline_pos).strip_edges()
		buffer = buffer.substr(newline_pos + 1)
		_client_buffers[client] = buffer
		
		if message.is_empty():
			continue
		
		_handle_message(client, message)


func _handle_message(client: StreamPeerTCP, message: String) -> void:
	var json := JSON.new()
	var err := json.parse(message)
	
	if err != OK:
		_send_error(client, null, -32700, "Parse error: " + json.get_error_message())
		return
	
	var request: Dictionary = json.data
	
	if not request.has("jsonrpc") or request.jsonrpc != "2.0":
		_send_error(client, request.get("id"), -32600, "Invalid request: must be JSON-RPC 2.0")
		return
	
	if not request.has("method") or not request.method is String:
		_send_error(client, request.get("id"), -32600, "Invalid request: missing method")
		return
	
	var method: String = request.method
	var params: Dictionary = request.get("params", {})
	var id: Variant = request.get("id")  # Can be null for notifications
	
	command_received.emit(method, params)
	
	# Route to handler
	var result: Variant = _handle_method(method, params)
	
	if id != null:
		if result is Dictionary and result.has("error"):
			_send_error(client, id, result.error.code, result.error.message)
		else:
			_send_result(client, id, result)


func _handle_method(method: String, params: Dictionary) -> Variant:
	match method:
		"ping":
			return {"pong": true, "version": VERSION}
		
		"get_state":
			return _get_state(params)
		
		"send_input":
			return _send_input(params)
		
		"screenshot":
			return _screenshot(params)
		
		"scene_change":
			return _scene_change(params)
		
		"call_method":
			return _call_method(params)
		
		"query":
			return _query(params)
		
		_:
			return {"error": {"code": -32601, "message": "Method not found: " + method}}


# =============================================================================
# RPC Methods
# =============================================================================

func _get_state(_params: Dictionary) -> Dictionary:
	var state: Dictionary = {
		"timestamp_ms": Time.get_ticks_msec(),
		"version": VERSION,
	}
	
	# Scene info
	var current_scene := get_tree().current_scene
	if current_scene:
		state["scene"] = {
			"current": current_scene.scene_file_path,
			"name": current_scene.name,
		}
	
	# Find player (common patterns)
	var player := _find_player()
	if player:
		state["player"] = _serialize_player(player)
	
	# World state from custom hooks
	state["world"] = _get_world_state()
	
	# NPCs
	var npcs := _get_npcs()
	if not npcs.is_empty():
		state["npcs"] = npcs
	
	# UI state
	state["ui"] = _get_ui_state()
	
	# Camera
	var camera := get_viewport().get_camera_2d()
	if camera:
		state["camera"] = {
			"position": {"x": camera.global_position.x, "y": camera.global_position.y},
			"zoom": {"x": camera.zoom.x, "y": camera.zoom.y},
		}
	
	# Custom state from game nodes
	state["custom"] = _collect_custom_state()
	
	return state


func _send_input(params: Dictionary) -> Dictionary:
	var action: String = params.get("action", "")
	if action.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'action' parameter"}}
	
	if not InputMap.has_action(action):
		return {"error": {"code": -32602, "message": "Unknown action: " + action}}
	
	var duration_ms: int = params.get("duration_ms", 100)  # Default 100ms hold
	
	# Press the action
	Input.action_press(action)
	
	# Schedule release after duration
	if duration_ms > 0:
		get_tree().create_timer(duration_ms / 1000.0).timeout.connect(
			func(): Input.action_release(action)
		)
	else:
		call_deferred("_deferred_release_action", action)
	
	return {"success": true, "action": action, "duration_ms": duration_ms, "executed_at": Time.get_ticks_msec()}


func _deferred_release_action(action: String) -> void:
	Input.action_release(action)


func _screenshot(params: Dictionary) -> Dictionary:
	var scale: float = params.get("scale", 1.0)
	var format: String = params.get("format", "png")
	
	# Capture viewport
	var viewport := get_viewport()
	var img := viewport.get_texture().get_image()
	
	if scale != 1.0:
		var new_size := Vector2i(int(img.get_width() * scale), int(img.get_height() * scale))
		img.resize(new_size.x, new_size.y)
	
	# Save to user data dir
	var timestamp := Time.get_unix_time_from_system()
	var filename := "playtest_%d.%s" % [int(timestamp), format]
	var screenshots_dir := OS.get_user_data_dir() + "/screenshots"
	
	# Ensure directory exists
	DirAccess.make_dir_recursive_absolute(screenshots_dir)
	
	var path := screenshots_dir + "/" + filename
	
	var err: int
	match format:
		"png":
			err = img.save_png(path)
		"jpg", "jpeg":
			err = img.save_jpg(path)
		_:
			return {"error": {"code": -32602, "message": "Unknown format: " + format}}
	
	if err != OK:
		return {"error": {"code": -32603, "message": "Failed to save screenshot"}}
	
	return {
		"path": path,
		"width": img.get_width(),
		"height": img.get_height(),
		"timestamp_ms": Time.get_ticks_msec(),
	}


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
	
	if node_path.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'node' parameter"}}
	if method_name.is_empty():
		return {"error": {"code": -32602, "message": "Missing 'method' parameter"}}
	
	var node := get_node_or_null(node_path)
	if node == null:
		return {"error": {"code": -32602, "message": "Node not found: " + node_path}}
	
	if not node.has_method(method_name):
		return {"error": {"code": -32602, "message": "Method not found: " + method_name}}
	
	var result: Variant = node.callv(method_name, args)
	
	return {"success": true, "result": result}


func _query(params: Dictionary) -> Dictionary:
	var query_type: String = params.get("type", "")
	
	match query_type:
		"entity":
			return _query_entity(params.get("filter", {}))
		"entities_near":
			var pos: Dictionary = params.get("position", {})
			var radius: float = params.get("radius", 5.0)
			return _query_entities_near(Vector2(pos.get("x", 0), pos.get("y", 0)), radius)
		"tile":
			var pos: Dictionary = params.get("position", {})
			return _query_tile(Vector2i(pos.get("x", 0), pos.get("y", 0)))
		"node":
			return _query_node(params.get("path", ""))
		_:
			return {"error": {"code": -32602, "message": "Unknown query type: " + query_type}}


# =============================================================================
# Helpers - Game State
# =============================================================================

func _find_player() -> Node:
	# Try finding by group (LOOP uses this)
	var players := get_tree().get_nodes_in_group("player")
	if not players.is_empty():
		return players[0]
	
	# Try common patterns
	var patterns: Array[String] = [
		"/root/Main/Player",
		"/root/Game/Player", 
		"/root/World/Player",
	]
	
	for pattern in patterns:
		var node := get_node_or_null(pattern)
		if node:
			return node
	
	return null


func _serialize_player(player: Node) -> Dictionary:
	var data: Dictionary = {
		"exists": true,
		"name": player.name,
	}
	
	# Position
	if player is Node2D:
		data["position"] = {"x": player.global_position.x, "y": player.global_position.y}
	elif player is Node3D:
		data["position"] = {"x": player.global_position.x, "y": player.global_position.y, "z": player.global_position.z}
	
	# Custom playtest data (LOOP implements _playtest_get_state)
	if player.has_method("_playtest_get_state"):
		data.merge(player._playtest_get_state())
	
	return data


func _get_world_state() -> Dictionary:
	var state: Dictionary = {}
	
	# Check GameManager
	if has_node("/root/GameManager"):
		var gm := get_node("/root/GameManager")
		if gm.has_method("_playtest_get_state"):
			state.merge(gm._playtest_get_state())
	
	# Check TimeManager
	if has_node("/root/TimeManager"):
		var tm := get_node("/root/TimeManager")
		if tm.has_method("_playtest_get_state"):
			state.merge(tm._playtest_get_state())
	
	return state


func _get_npcs() -> Array:
	var npcs: Array = []
	
	# Find by group
	for npc in get_tree().get_nodes_in_group("npc"):
		npcs.append(_serialize_npc(npc))
	
	for npc in get_tree().get_nodes_in_group("colonists"):
		if not _contains_node(npcs, npc):
			npcs.append(_serialize_npc(npc))
	
	return npcs


func _contains_node(arr: Array, node: Node) -> bool:
	for item in arr:
		if item.get("_node_id") == node.get_instance_id():
			return true
	return false


func _serialize_npc(npc: Node) -> Dictionary:
	var data: Dictionary = {
		"_node_id": npc.get_instance_id(),
		"name": npc.name,
	}
	
	if npc is Node2D:
		data["position"] = {"x": npc.global_position.x, "y": npc.global_position.y}
	
	# Custom
	if npc.has_method("_playtest_get_state"):
		data.merge(npc._playtest_get_state())
	
	return data


func _get_ui_state() -> Dictionary:
	var state: Dictionary = {
		"open_panels": [] as Array[String],
	}
	
	# Check for common UI patterns
	var ui_root := get_node_or_null("/root/Main/UI")
	if ui_root == null:
		ui_root = get_node_or_null("/root/UI")
	
	if ui_root:
		for child in ui_root.get_children():
			if child is Control and child.visible:
				state["open_panels"].append(child.name)
	
	return state


func _collect_custom_state() -> Dictionary:
	var custom: Dictionary = {}
	
	# Find all nodes that implement _playtest_get_state
	if get_tree().current_scene:
		_collect_custom_recursive(get_tree().current_scene, custom)
	
	return custom


func _collect_custom_recursive(node: Node, custom: Dictionary) -> void:
	if node.has_method("_playtest_get_state") and node != self:
		var key := node.get_path().get_concatenated_names().replace("/", "_")
		custom[key] = node._playtest_get_state()
	
	for child in node.get_children():
		_collect_custom_recursive(child, custom)


# =============================================================================
# Helpers - Queries
# =============================================================================

func _query_entity(filter: Dictionary) -> Dictionary:
	var id: Variant = filter.get("id")
	var name_filter: String = filter.get("name", "")
	
	# Search by id
	if id != null:
		var node := instance_from_id(id)
		if node:
			return _serialize_any_node(node)
	
	# Search by name
	if not name_filter.is_empty() and get_tree().current_scene:
		var node := _find_node_by_name(get_tree().current_scene, name_filter)
		if node:
			return _serialize_any_node(node)
	
	return {"error": {"code": -32602, "message": "Entity not found"}}


func _find_node_by_name(root: Node, search_name: String) -> Node:
	if root.name.to_lower() == search_name.to_lower():
		return root
	
	for child in root.get_children():
		var found := _find_node_by_name(child, search_name)
		if found:
			return found
	
	return null


func _query_entities_near(position: Vector2, radius: float) -> Dictionary:
	var entities: Array = []
	
	if get_tree().current_scene:
		_find_entities_near_recursive(get_tree().current_scene, position, radius, entities)
	
	return {"entities": entities, "count": entities.size()}


func _find_entities_near_recursive(node: Node, position: Vector2, radius: float, results: Array) -> void:
	if node is Node2D:
		var dist: float = node.global_position.distance_to(position)
		if dist <= radius:
			results.append({
				"name": node.name,
				"position": {"x": node.global_position.x, "y": node.global_position.y},
				"distance": dist,
			})
	
	for child in node.get_children():
		_find_entities_near_recursive(child, position, radius, results)


func _query_tile(position: Vector2i) -> Dictionary:
	# Find tilemap
	var tilemaps := get_tree().get_nodes_in_group("tilemap")
	if tilemaps.is_empty():
		# Try to find any TileMap
		if get_tree().current_scene:
			tilemaps = _find_nodes_of_type(get_tree().current_scene, "TileMapLayer")
	
	if tilemaps.is_empty():
		return {"error": {"code": -32602, "message": "No TileMap found"}}
	
	var tilemap: TileMapLayer = tilemaps[0]
	var data := tilemap.get_cell_tile_data(position)
	
	if data == null:
		return {"position": {"x": position.x, "y": position.y}, "empty": true}
	
	return {
		"position": {"x": position.x, "y": position.y},
		"source_id": tilemap.get_cell_source_id(position),
		"atlas_coords": {
			"x": tilemap.get_cell_atlas_coords(position).x,
			"y": tilemap.get_cell_atlas_coords(position).y,
		},
	}


func _query_node(path: String) -> Dictionary:
	var node := get_node_or_null(path)
	if node == null:
		return {"error": {"code": -32602, "message": "Node not found: " + path}}
	
	return _serialize_any_node(node)


func _serialize_any_node(node: Node) -> Dictionary:
	var data: Dictionary = {
		"name": node.name,
		"class": node.get_class(),
		"path": str(node.get_path()),
	}
	
	if node is Node2D:
		data["position"] = {"x": node.global_position.x, "y": node.global_position.y}
		data["rotation"] = node.rotation
		data["scale"] = {"x": node.scale.x, "y": node.scale.y}
		data["visible"] = node.visible
	
	if node is Control:
		data["position"] = {"x": node.global_position.x, "y": node.global_position.y}
		data["size"] = {"x": node.size.x, "y": node.size.y}
		data["visible"] = node.visible
	
	if node.has_method("_playtest_get_state"):
		data.merge(node._playtest_get_state())
	
	return data


func _find_nodes_of_type(root: Node, type_name: String) -> Array:
	var results: Array = []
	_find_nodes_of_type_recursive(root, type_name, results)
	return results


func _find_nodes_of_type_recursive(node: Node, type_name: String, results: Array) -> void:
	if node.get_class() == type_name:
		results.append(node)
	
	for child in node.get_children():
		_find_nodes_of_type_recursive(child, type_name, results)


# =============================================================================
# Response Helpers
# =============================================================================

func _send_result(client: StreamPeerTCP, id: Variant, result: Variant) -> void:
	var response: Dictionary = {
		"jsonrpc": "2.0",
		"id": id,
		"result": result,
	}
	_send_json(client, response)


func _send_error(client: StreamPeerTCP, id: Variant, code: int, message: String) -> void:
	var response: Dictionary = {
		"jsonrpc": "2.0",
		"id": id,
		"error": {
			"code": code,
			"message": message,
		}
	}
	_send_json(client, response)


func _send_json(client: StreamPeerTCP, data: Dictionary) -> void:
	var json_str := JSON.stringify(data) + "\n"
	client.put_data(json_str.to_utf8_buffer())


func _remove_client(client: StreamPeerTCP) -> void:
	var client_id := client.get_instance_id()
	_clients.erase(client)
	_client_buffers.erase(client)
	print("[PlaytestServer] Client disconnected: %d" % client_id)
	client_disconnected.emit(client_id)


func _exit_tree() -> void:
	if _server:
		_server.stop()
		print("[PlaytestServer] Server stopped")

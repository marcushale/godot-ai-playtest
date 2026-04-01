"""Async TCP client for communicating with PlaytestServer."""

import asyncio
import json
from collections.abc import Callable
from typing import Any


class PlaytestClient:
    """Async client for Godot PlaytestServer.

    Usage:
        async with PlaytestClient() as client:
            state = await client.get_state()
            await client.send_input("move_right", duration_ms=500)
    """

    def __init__(self, host: str = "127.0.0.1", port: int = 9876):
        self.host = host
        self.port = port
        self._reader: asyncio.StreamReader | None = None
        self._writer: asyncio.StreamWriter | None = None
        self._request_id = 0
        self._pending: dict[int, asyncio.Future[dict[str, Any]]] = {}
        self._event_handlers: list[Callable[[str, dict[str, Any]], None]] = []
        self._read_task: asyncio.Task[None] | None = None

    async def connect(self) -> None:
        """Connect to the PlaytestServer."""
        self._reader, self._writer = await asyncio.open_connection(self.host, self.port)
        self._read_task = asyncio.create_task(self._read_loop())

    async def disconnect(self) -> None:
        """Disconnect from the PlaytestServer."""
        if self._read_task:
            self._read_task.cancel()
            try:
                await self._read_task
            except asyncio.CancelledError:
                pass

        if self._writer:
            self._writer.close()
            await self._writer.wait_closed()

        self._reader = None
        self._writer = None

    async def __aenter__(self) -> "PlaytestClient":
        await self.connect()
        return self

    async def __aexit__(self, *args: Any) -> None:
        await self.disconnect()

    async def _read_loop(self) -> None:
        """Background task to read responses from server."""
        assert self._reader is not None

        buffer = ""
        while True:
            try:
                data = await self._reader.read(65536)
                if not data:
                    break

                buffer += data.decode("utf-8")

                while "\n" in buffer:
                    line, buffer = buffer.split("\n", 1)
                    if line.strip():
                        self._handle_message(json.loads(line))

            except asyncio.CancelledError:
                break
            except Exception as e:
                print(f"Read error: {e}")
                break

    def _handle_message(self, message: dict[str, Any]) -> None:
        """Handle incoming JSON-RPC message."""
        if "id" in message and message["id"] in self._pending:
            future = self._pending.pop(message["id"])
            if "error" in message:
                future.set_exception(PlaytestError(message["error"]))
            else:
                future.set_result(message.get("result", {}))

        elif message.get("method") == "event":
            params = message.get("params", {})
            event_type = params.get("type", "")
            event_data = params.get("data", {})

            for handler in self._event_handlers:
                try:
                    handler(event_type, event_data)
                except Exception as e:
                    print(f"Event handler error: {e}")

    async def _call(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        """Make a JSON-RPC call and wait for response."""
        assert self._writer is not None

        self._request_id += 1
        request_id = self._request_id

        request = {
            "jsonrpc": "2.0",
            "method": method,
            "id": request_id,
        }
        if params:
            request["params"] = params

        future: asyncio.Future[dict[str, Any]] = asyncio.get_event_loop().create_future()
        self._pending[request_id] = future

        self._writer.write((json.dumps(request) + "\n").encode("utf-8"))
        await self._writer.drain()

        return await asyncio.wait_for(future, timeout=30.0)

    # =========================================================================
    # Core
    # =========================================================================

    async def ping(self) -> dict[str, Any]:
        """Check connection and get server version."""
        return await self._call("ping")

    async def get_state(
        self,
        include_npcs: bool = True,
        include_inventory: bool = False,
        include_performance: bool = False,
    ) -> dict[str, Any]:
        """Get full game state snapshot.

        Args:
            include_npcs: Include NPC data (default True)
            include_inventory: Include inventory data (default False)
            include_performance: Include performance metrics (default False)
        """
        return await self._call(
            "get_state",
            {
                "include_npcs": include_npcs,
                "include_inventory": include_inventory,
                "include_performance": include_performance,
            },
        )

    # =========================================================================
    # Input - GodotTestDriver-inspired patterns
    # =========================================================================

    async def send_input(
        self,
        action: str,
        duration_ms: int = 100,
        strength: float = 1.0,
    ) -> dict[str, Any]:
        """Send player input with duration.

        Args:
            action: Input action name (e.g., "move_right", "interact")
            duration_ms: Hold duration in milliseconds
            strength: Action strength (0.0 - 1.0)
        """
        return await self._call(
            "send_input",
            {
                "action": action,
                "duration_ms": duration_ms,
                "strength": strength,
            },
        )

    async def hold_action(self, action: str, strength: float = 1.0) -> dict[str, Any]:
        """Hold an input action indefinitely until release_action is called.

        Args:
            action: Input action name
            strength: Action strength (0.0 - 1.0)
        """
        return await self._call("hold_action", {"action": action, "strength": strength})

    async def release_action(self, action: str) -> dict[str, Any]:
        """Release a held input action.

        Args:
            action: Input action name to release
        """
        return await self._call("release_action", {"action": action})

    async def click_at(
        self,
        x: float,
        y: float,
        button: int = 1,
    ) -> dict[str, Any]:
        """Click the mouse at a specific position.

        Args:
            x: X coordinate in viewport space
            y: Y coordinate in viewport space
            button: Mouse button (1=left, 2=right, 3=middle)
        """
        return await self._call("click_at", {"x": x, "y": y, "button": button})

    async def move_mouse(self, x: float, y: float) -> dict[str, Any]:
        """Move the mouse to a specific position."""
        return await self._call("move_mouse", {"x": x, "y": y})

    # =========================================================================
    # Time Control
    # =========================================================================

    async def time_advance(
        self,
        days: int = 0,
        hours: int = 0,
        minutes: int = 0,
    ) -> dict[str, Any]:
        """Advance game time.

        Args:
            days: Days to advance
            hours: Hours to advance
            minutes: Minutes to advance

        Returns:
            Dict with success, advanced amounts, and current_time
        """
        return await self._call(
            "time_advance",
            {
                "days": days,
                "hours": hours,
                "minutes": minutes,
            },
        )

    async def time_set(
        self,
        day: int | None = None,
        hour: int | None = None,
        minute: int | None = None,
        season: str | None = None,
        year: int | None = None,
    ) -> dict[str, Any]:
        """Set game time directly.

        Args:
            day: Day number
            hour: Hour (0-23)
            minute: Minute (0-59)
            season: Season name ("SPRING", "SUMMER", "AUTUMN", "WINTER")
            year: Year number
        """
        params = {}
        if day is not None:
            params["day"] = day
        if hour is not None:
            params["hour"] = hour
        if minute is not None:
            params["minute"] = minute
        if season is not None:
            params["season"] = season
        if year is not None:
            params["year"] = year
        return await self._call("time_set", params)

    async def time_pause(self) -> dict[str, Any]:
        """Pause game time."""
        return await self._call("time_pause", {})

    async def time_resume(self) -> dict[str, Any]:
        """Resume game time."""
        return await self._call("time_resume", {})

    # =========================================================================
    # NPC State
    # =========================================================================

    async def get_npc(self, name: str) -> dict[str, Any]:
        """Get detailed info about a specific NPC.

        Args:
            name: NPC name (case-insensitive)

        Returns:
            Dict with found, npc (if found) containing position, relationship,
            dialogue_flags, quest_state, etc.
        """
        return await self._call("get_npc", {"name": name})

    async def get_all_npcs(self) -> dict[str, Any]:
        """Get info about all NPCs.

        Returns:
            Dict with npcs array and count
        """
        return await self._call("get_all_npcs", {})

    # =========================================================================
    # Inventory
    # =========================================================================

    async def get_inventory(self) -> dict[str, Any]:
        """Get player inventory contents.

        Returns:
            Dict with items array, capacity, and used count
        """
        return await self._call("get_inventory", {})

    async def add_item(self, item: str, quantity: int = 1) -> dict[str, Any]:
        """Add item to player inventory.

        Args:
            item: Item name/ID
            quantity: Amount to add
        """
        return await self._call("add_item", {"item": item, "quantity": quantity})

    async def remove_item(self, item: str, quantity: int = 1) -> dict[str, Any]:
        """Remove item from player inventory.

        Args:
            item: Item name/ID
            quantity: Amount to remove
        """
        return await self._call("remove_item", {"item": item, "quantity": quantity})

    # =========================================================================
    # Save/Load
    # =========================================================================

    async def save_game(self, slot: str = "playtest_save") -> dict[str, Any]:
        """Save the game.

        Args:
            slot: Save slot name
        """
        return await self._call("save_game", {"slot": slot})

    async def load_game(self, slot: str = "playtest_save") -> dict[str, Any]:
        """Load a saved game.

        Args:
            slot: Save slot name
        """
        return await self._call("load_game", {"slot": slot})

    async def list_saves(self) -> dict[str, Any]:
        """List all save files.

        Returns:
            Dict with saves array (name, path, modified) and count
        """
        return await self._call("list_saves", {})

    async def delete_save(self, slot: str) -> dict[str, Any]:
        """Delete a save file.

        Args:
            slot: Save slot name
        """
        return await self._call("delete_save", {"slot": slot})

    # =========================================================================
    # Performance
    # =========================================================================

    async def get_performance(self) -> dict[str, Any]:
        """Get performance metrics.

        Returns:
            Dict with fps, frame_time_ms, avg_frame_ms, max_frame_ms,
            memory (static_mb, peak_mb), objects (total, orphan_nodes, resources),
            rendering (draw_calls, vertices)
        """
        return await self._call("get_performance", {})

    async def assert_performance(
        self,
        min_fps: float | None = None,
        max_frame_ms: float | None = None,
        max_avg_frame_ms: float | None = None,
        max_memory_mb: float | None = None,
        max_orphan_nodes: int | None = None,
    ) -> dict[str, Any]:
        """Assert performance meets requirements.

        Args:
            min_fps: Minimum acceptable FPS
            max_frame_ms: Maximum single frame time in ms
            max_avg_frame_ms: Maximum average frame time in ms
            max_memory_mb: Maximum memory usage in MB
            max_orphan_nodes: Maximum orphan node count

        Returns:
            Dict with success, failures array, and performance metrics
        """
        params = {}
        if min_fps is not None:
            params["min_fps"] = min_fps
        if max_frame_ms is not None:
            params["max_frame_ms"] = max_frame_ms
        if max_avg_frame_ms is not None:
            params["max_avg_frame_ms"] = max_avg_frame_ms
        if max_memory_mb is not None:
            params["max_memory_mb"] = max_memory_mb
        if max_orphan_nodes is not None:
            params["max_orphan_nodes"] = max_orphan_nodes
        return await self._call("assert_performance", params)

    # =========================================================================
    # Error Capture
    # =========================================================================

    async def start_error_capture(self) -> dict[str, Any]:
        """Start capturing errors and warnings.

        Returns:
            Dict with success and capturing status
        """
        return await self._call("start_error_capture", {})

    async def stop_error_capture(self) -> dict[str, Any]:
        """Stop capturing errors.

        Returns:
            Dict with success, capturing status, and error_count
        """
        return await self._call("stop_error_capture", {})

    async def get_captured_errors(self) -> dict[str, Any]:
        """Get captured errors.

        Returns:
            Dict with errors array, count, and capturing status
        """
        return await self._call("get_captured_errors", {})

    # =========================================================================
    # Recording & Playback
    # =========================================================================

    async def start_recording(self) -> dict[str, Any]:
        """Start recording inputs.

        Returns:
            Dict with success and recording status
        """
        return await self._call("start_recording", {})

    async def stop_recording(self, save_to: str | None = None) -> dict[str, Any]:
        """Stop recording inputs.

        Args:
            save_to: Optional path to save recording

        Returns:
            Dict with success, duration_ms, input_count, and optionally inputs
        """
        params = {}
        if save_to:
            params["save_to"] = save_to
        return await self._call("stop_recording", params)

    async def playback(
        self,
        inputs: list[dict[str, Any]] | None = None,
        load_from: str | None = None,
    ) -> dict[str, Any]:
        """Play back recorded inputs.

        Args:
            inputs: List of input events to replay
            load_from: Path to load recording from

        Returns:
            Dict with success and input_count
        """
        params = {}
        if inputs:
            params["inputs"] = inputs
        if load_from:
            params["load_from"] = load_from
        return await self._call("playback", params)

    # =========================================================================
    # Visual Regression
    # =========================================================================

    async def screenshot(
        self,
        name: str | None = None,
        scale: float = 1.0,
        format: str = "png",
    ) -> dict[str, Any]:
        """Capture a screenshot.

        Args:
            name: Optional filename (without extension)
            scale: Scale factor
            format: Image format (png or jpg)

        Returns:
            Dict with success, path, and size
        """
        params = {"scale": scale, "format": format}
        if name:
            params["name"] = name
        return await self._call("screenshot", params)

    async def save_baseline(self, name: str) -> dict[str, Any]:
        """Save current screen as a baseline for comparison.

        Args:
            name: Baseline name

        Returns:
            Dict with success, path, and size
        """
        return await self._call("save_baseline", {"name": name})

    async def compare_screenshot(
        self,
        name: str,
        threshold: float = 0.01,
    ) -> dict[str, Any]:
        """Compare current screen against a baseline.

        Args:
            name: Baseline name to compare against
            threshold: Maximum allowed difference ratio (0.0 - 1.0)

        Returns:
            Dict with success, match, difference_ratio, different_pixels,
            total_pixels, threshold, and diff_image path if mismatch
        """
        return await self._call(
            "compare_screenshot",
            {
                "name": name,
                "threshold": threshold,
            },
        )

    # =========================================================================
    # Query
    # =========================================================================

    async def query_node(self, path: str) -> dict[str, Any]:
        """Query a node by path."""
        return await self._call("query", {"type": "node", "path": path})

    async def query_entities_near(
        self,
        x: float,
        y: float,
        radius: float = 100.0,
    ) -> dict[str, Any]:
        """Query entities near a position."""
        return await self._call(
            "query",
            {
                "type": "entities_near",
                "position": {"x": x, "y": y},
                "radius": radius,
            },
        )

    async def query_tile(self, x: int, y: int) -> dict[str, Any]:
        """Query tile at position."""
        return await self._call(
            "query",
            {
                "type": "tile",
                "position": {"x": x, "y": y},
            },
        )

    async def query_input_actions(self) -> dict[str, Any]:
        """Get list of all available input actions."""
        return await self._call("query", {"type": "input_actions"})

    # =========================================================================
    # World/Tile Query
    # =========================================================================

    async def get_tile(self, x: int, y: int) -> dict[str, Any]:
        """Get detailed tile info at world coordinates.

        Args:
            x: World tile X coordinate
            y: World tile Y coordinate

        Returns:
            Dict with tile info: ground_type, walkable, crop, etc.
        """
        return await self._call("get_tile", {"x": x, "y": y})

    async def get_tiles_in_radius(self, x: int, y: int, radius: int = 1) -> dict[str, Any]:
        """Get tiles in a radius around a point.

        Args:
            x: Center tile X
            y: Center tile Y
            radius: Radius in tiles

        Returns:
            Dict with tiles array
        """
        return await self._call("get_tiles_in_radius", {"x": x, "y": y, "radius": radius})

    async def get_entities_at(self, x: int, y: int, radius: float = 32.0) -> dict[str, Any]:
        """Get entities (NPCs, items, structures) near a tile.

        Args:
            x: Tile X coordinate
            y: Tile Y coordinate
            radius: Pixel radius to search

        Returns:
            Dict with entities array
        """
        return await self._call("get_entities_at", {"x": x, "y": y, "radius": radius})

    # =========================================================================
    # NPC Interaction
    # =========================================================================

    async def interact_npc(self, name: str) -> dict[str, Any]:
        """Interact with an NPC (triggers their interaction handler).

        Args:
            name: NPC name (e.g., "Iris", "Kael")

        Returns:
            Dict with success status
        """
        return await self._call("interact_npc", {"name": name})

    async def give_gift(self, npc: str, item: str, quantity: int = 1) -> dict[str, Any]:
        """Give an item to an NPC as a gift.

        Args:
            npc: NPC name
            item: Item ID
            quantity: Number of items

        Returns:
            Dict with success and NPC reaction
        """
        return await self._call("give_gift", {"npc": npc, "item": item, "quantity": quantity})

    async def talk_to_npc(self, npc: str, message: str = "") -> dict[str, Any]:
        """Start a conversation with an NPC.

        Args:
            npc: NPC name
            message: Optional message to send

        Returns:
            Dict with conversation state or NPC response
        """
        return await self._call("talk_to_npc", {"npc": npc, "message": message})

    # =========================================================================
    # Teleport
    # =========================================================================

    async def teleport_to(self, x: float, y: float, tile_coords: bool = False) -> dict[str, Any]:
        """Teleport the player to a position.

        Args:
            x: X coordinate (pixels or tiles)
            y: Y coordinate (pixels or tiles)
            tile_coords: If True, interpret x/y as tile coordinates

        Returns:
            Dict with old and new positions
        """
        return await self._call("teleport_to", {"x": x, "y": y, "tile_coords": tile_coords})

    async def teleport_to_npc(
        self, npc: str, offset_x: float = 32.0, offset_y: float = 0.0
    ) -> dict[str, Any]:
        """Teleport the player near an NPC.

        Args:
            npc: NPC name (e.g., "Iris")
            offset_x: X offset from NPC position
            offset_y: Y offset from NPC position

        Returns:
            Dict with NPC position and new player position
        """
        return await self._call(
            "teleport_to_npc", {"npc": npc, "offset_x": offset_x, "offset_y": offset_y}
        )

    # =========================================================================
    # Weather Control
    # =========================================================================

    async def get_weather(self) -> dict[str, Any]:
        """Get current weather conditions.

        Returns:
            Dict with weather_type (int), weather_name (str), available_types
        """
        return await self._call("get_weather", {})

    async def set_weather(self, weather: str | int) -> dict[str, Any]:
        """Set the weather.

        Args:
            weather: Weather name ("clear", "rain", "snow", "fog", "storm", "heat_wave")
                    or type int (0-5)

        Returns:
            Dict with old and new weather
        """
        return await self._call("set_weather", {"weather": weather})

    # =========================================================================
    # Goal/Quest System
    # =========================================================================

    async def get_goals(self) -> dict[str, Any]:
        """Get all NPC goals.

        Returns:
            Dict with count and goals array
        """
        return await self._call("get_goals", {})

    async def get_npc_goal(self, npc: str) -> dict[str, Any]:
        """Get a specific NPC's current goal.

        Args:
            npc: NPC name

        Returns:
            Dict with npc, has_goal, and goal details
        """
        return await self._call("get_npc_goal", {"npc": npc})

    async def complete_goal(self, npc: str) -> dict[str, Any]:
        """Force-complete an NPC's current goal.

        Args:
            npc: NPC name

        Returns:
            Dict with success status
        """
        return await self._call("complete_goal", {"npc": npc})

    # =========================================================================
    # Spawning
    # =========================================================================

    async def spawn_item(
        self,
        item: str,
        quantity: int = 1,
        x: float = 0.0,
        y: float = 0.0,
        near_player: bool = True,
        offset_x: float = 32.0,
        offset_y: float = 0.0,
    ) -> dict[str, Any]:
        """Spawn an item in the world.

        Args:
            item: Item ID (e.g., "wood_log", "stone_chunk")
            quantity: Number of items
            x: X position (if near_player=False)
            y: Y position (if near_player=False)
            near_player: If True, spawn near player with offset
            offset_x: X offset from player
            offset_y: Y offset from player

        Returns:
            Dict with success, position, and spawn method used
        """
        return await self._call(
            "spawn_item",
            {
                "item": item,
                "quantity": quantity,
                "x": x,
                "y": y,
                "near_player": near_player,
                "offset_x": offset_x,
                "offset_y": offset_y,
            },
        )

    # =========================================================================
    # Universal Hook System
    # =========================================================================

    async def list_systems(self) -> dict[str, Any]:
        """List all registered playtest systems (nodes in the 'playtest' group).

        Returns:
            Dict with count and systems array. Each system has name, node_path,
            methods (advertised hooks), and has_state flag.
        """
        return await self._call("list_systems", {})

    async def discover_hooks(self) -> dict[str, Any]:
        """Discover every _playtest_* method in the scene tree.

        More thorough than list_systems — finds hooks on nodes even if they
        haven't joined the 'playtest' group. Useful during development.

        Returns:
            Dict with count, nodes array, and a tip about group registration.
        """
        return await self._call("discover_hooks", {})

    async def get_system_state(self, system: str) -> dict[str, Any]:
        """Call _playtest_get_state() on a registered system.

        Args:
            system: System name (case-insensitive, e.g. "weather", "SaveManager")

        Returns:
            Dict with system name and state dict.
        """
        return await self._call("get_system_state", {"system": system})

    async def call_system(
        self,
        system: str,
        method: str,
        params: dict[str, Any] | None = None,
        value: Any = None,
    ) -> dict[str, Any]:
        """Call a hook method on a registered system.

        Routes to _playtest_call_<method>(params) or _playtest_set_<method>(value)
        depending on which hook the node implements.

        Args:
            system: System name (e.g. "weather")
            method: Method name without _playtest_ prefix (e.g. "set_weather")
            params: Forwarded to _playtest_call_<method>() hooks
            value: Forwarded to _playtest_set_<method>() hooks

        Returns:
            Whatever the hook returns.
        """
        payload: dict[str, Any] = {"system": system, "method": method}
        if params is not None:
            payload["params"] = params
        if value is not None:
            payload["value"] = value
        return await self._call("call_system", payload)

    async def hook(self, system_method: str, **kwargs: Any) -> dict[str, Any]:
        """Convenience shorthand using dot-notation.

        Equivalent to call_system but accepts "System.method" as a single
        string. Keyword arguments are forwarded as params.

        Example::

            await client.hook("weather.set_weather", weather="rain")
            await client.hook("NPC_Iris.get_state")

        Args:
            system_method: "System.method" string
            **kwargs: Forwarded as the params dict to the hook

        Returns:
            Whatever the hook returns.
        """
        return await self._call(system_method, dict(kwargs))

    # =========================================================================
    # Wait Conditions
    # =========================================================================

    async def wait_for(
        self,
        condition: str,
        timeout_ms: int = 5000,
    ) -> dict[str, Any]:
        """Check if a condition is true.

        Note: The actual waiting loop should be done client-side.
        This method checks the condition once.

        Args:
            condition: Condition string (e.g., "player.health > 50")
            timeout_ms: Timeout hint for client-side loop

        Returns:
            Dict with condition, met (bool), and current_time_ms
        """
        return await self._call(
            "wait_for",
            {
                "condition": condition,
                "timeout_ms": timeout_ms,
            },
        )

    async def wait_until(
        self,
        condition: str,
        timeout_ms: int = 5000,
        poll_ms: int = 100,
    ) -> dict[str, Any]:
        """Wait until a condition is true (client-side polling).

        Args:
            condition: Condition string
            timeout_ms: Maximum wait time
            poll_ms: Time between checks

        Returns:
            Dict with success, waited_ms, and condition_met
        """
        start_ms = 0
        elapsed_ms = 0

        while elapsed_ms < timeout_ms:
            result = await self.wait_for(condition, timeout_ms - elapsed_ms)

            if start_ms == 0:
                start_ms = result.get("current_time_ms", 0)

            if result.get("met", False):
                return {
                    "success": True,
                    "waited_ms": elapsed_ms,
                    "condition_met": True,
                }

            await asyncio.sleep(poll_ms / 1000.0)
            elapsed_ms = result.get("current_time_ms", 0) - start_ms

        return {
            "success": False,
            "waited_ms": elapsed_ms,
            "condition_met": False,
            "timeout": True,
        }

    # =========================================================================
    # Scene/Node Control
    # =========================================================================

    async def scene_change(self, scene: str) -> dict[str, Any]:
        """Change to a different scene.

        Args:
            scene: Scene path (e.g., "res://scenes/main/main.tscn")
        """
        return await self._call("scene_change", {"scene": scene})

    async def call_method(
        self,
        node: str,
        method: str,
        args: list[Any] | None = None,
    ) -> dict[str, Any]:
        """Call a method on a node.

        Args:
            node: Node path (e.g., "/root/TitleScreen")
            method: Method name to call
            args: Arguments to pass to the method
        """
        return await self._call(
            "call_method",
            {
                "node": node,
                "method": method,
                "args": args or [],
            },
        )

    async def execute(self, expression: str) -> dict[str, Any]:
        """Execute a GDScript expression (debug only).

        Warning: This is potentially dangerous and may be disabled.
        """
        return await self._call("execute", {"expression": expression})

    # =========================================================================
    # Event Handling
    # =========================================================================

    def on_event(self, handler: Callable[[str, dict[str, Any]], None]) -> None:
        """Register an event handler."""
        self._event_handlers.append(handler)


class PlaytestError(Exception):
    """Error from PlaytestServer."""

    def __init__(self, error: dict[str, Any]):
        self.code = error.get("code", -1)
        self.message = error.get("message", "Unknown error")
        super().__init__(f"[{self.code}] {self.message}")

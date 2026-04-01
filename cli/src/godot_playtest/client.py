"""Async TCP client for communicating with PlaytestServer."""

import asyncio
import json
from typing import Any, Callable


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
            # Response to a request
            future = self._pending.pop(message["id"])
            if "error" in message:
                future.set_exception(PlaytestError(message["error"]))
            else:
                future.set_result(message.get("result", {}))
        
        elif message.get("method") == "event":
            # Event notification
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
    # Public API
    # =========================================================================
    
    async def ping(self) -> dict[str, Any]:
        """Check connection and get server version."""
        return await self._call("ping")
    
    async def get_state(self) -> dict[str, Any]:
        """Get full game state snapshot."""
        return await self._call("get_state")
    
    async def send_input(
        self,
        action: str,
        duration_ms: int = 0,
        press: bool = True,
        release: bool = True,
    ) -> dict[str, Any]:
        """Send player input.
        
        Args:
            action: Input action name (e.g., "move_right", "interact")
            duration_ms: Hold duration in milliseconds (0 for tap)
            press: Whether to press the action
            release: Whether to release the action
        """
        return await self._call("send_input", {
            "action": action,
            "duration_ms": duration_ms,
            "press": press,
            "release": release,
        })
    
    async def send_sequence(self, sequence: list[dict[str, Any] | str]) -> dict[str, Any]:
        """Send a sequence of inputs.
        
        Args:
            sequence: List of input dictionaries or shorthand strings
                      e.g., [{"action": "move_right", "duration_ms": 500}, "interact"]
                      or ["right:500", "wait:100", "interact"]
        """
        return await self._call("send_input", {"sequence": sequence})
    
    async def screenshot(
        self,
        include_ui: bool = True,
        scale: float = 1.0,
        format: str = "png",
    ) -> dict[str, Any]:
        """Capture a screenshot.
        
        Returns:
            Dictionary with 'path', 'width', 'height', 'timestamp_ms'
        """
        return await self._call("screenshot", {
            "include_ui": include_ui,
            "scale": scale,
            "format": format,
        })
    
    async def query_entity(self, filter: dict[str, Any]) -> dict[str, Any]:
        """Query a specific entity."""
        return await self._call("query", {"type": "entity", "filter": filter})
    
    async def query_entities_near(
        self,
        x: float,
        y: float,
        radius: float = 5.0,
    ) -> dict[str, Any]:
        """Query entities near a position."""
        return await self._call("query", {
            "type": "entities_near",
            "position": {"x": x, "y": y},
            "radius": radius,
        })
    
    async def query_tile(self, x: int, y: int) -> dict[str, Any]:
        """Query tile at position."""
        return await self._call("query", {
            "type": "tile",
            "position": {"x": x, "y": y},
        })
    
    async def query_node(self, path: str) -> dict[str, Any]:
        """Query a node by path."""
        return await self._call("query", {"type": "node", "path": path})
    
    async def wait_for(
        self,
        condition: str,
        timeout_ms: int = 5000,
    ) -> dict[str, Any]:
        """Wait for a condition to be true.
        
        Args:
            condition: Condition string (e.g., "player.state == 'idle'")
            timeout_ms: Maximum wait time in milliseconds
        """
        return await self._call("wait", {
            "condition": condition,
            "timeout_ms": timeout_ms,
        })
    
    async def wait_ms(self, duration_ms: int) -> dict[str, Any]:
        """Wait for a fixed duration."""
        return await self._call("wait", {"timeout_ms": duration_ms})
    
    async def subscribe_events(self, event_types: list[str]) -> dict[str, Any]:
        """Subscribe to game events."""
        return await self._call("events", {"subscribe": event_types})
    
    async def unsubscribe_events(self, event_types: list[str]) -> dict[str, Any]:
        """Unsubscribe from game events."""
        return await self._call("events", {"unsubscribe": event_types})
    
    def on_event(self, handler: Callable[[str, dict[str, Any]], None]) -> None:
        """Register an event handler."""
        self._event_handlers.append(handler)
    
    async def execute(self, expression: str) -> dict[str, Any]:
        """Execute a GDScript expression (debug only).
        
        Warning: This is potentially dangerous and may be disabled on the server.
        """
        return await self._call("execute", {"expression": expression})


class PlaytestError(Exception):
    """Error from PlaytestServer."""
    
    def __init__(self, error: dict[str, Any]):
        self.code = error.get("code", -1)
        self.message = error.get("message", "Unknown error")
        super().__init__(f"[{self.code}] {self.message}")

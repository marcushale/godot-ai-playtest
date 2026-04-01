"""YAML scenario runner for Godot Playtest."""

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

from .client import PlaytestClient, PlaytestError


@dataclass
class StepResult:
    """Result of a single scenario step."""
    name: str
    success: bool
    duration_ms: int = 0
    error: str | None = None
    screenshot: str | None = None
    state_snapshot: dict[str, Any] | None = None


@dataclass
class ScenarioResult:
    """Result of a complete scenario run."""
    name: str
    success: bool
    steps: list[StepResult] = field(default_factory=list)
    total_duration_ms: int = 0
    error: str | None = None
    
    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            "name": self.name,
            "success": self.success,
            "total_duration_ms": self.total_duration_ms,
            "error": self.error,
            "steps": [
                {
                    "name": s.name,
                    "success": s.success,
                    "duration_ms": s.duration_ms,
                    "error": s.error,
                    "screenshot": s.screenshot,
                }
                for s in self.steps
            ],
        }
    
    def to_text(self) -> str:
        """Convert to human-readable text."""
        lines = [
            f"Scenario: {self.name}",
            f"Status: {'✓ PASSED' if self.success else '✗ FAILED'}",
            f"Duration: {self.total_duration_ms}ms",
            "",
            "Steps:",
        ]
        
        for step in self.steps:
            status = "✓" if step.success else "✗"
            lines.append(f"  {status} {step.name} ({step.duration_ms}ms)")
            if step.error:
                lines.append(f"      Error: {step.error}")
            if step.screenshot:
                lines.append(f"      Screenshot: {step.screenshot}")
        
        if self.error:
            lines.append(f"\nError: {self.error}")
        
        return "\n".join(lines)
    
    def to_junit(self) -> str:
        """Convert to JUnit XML format."""
        failures = sum(1 for s in self.steps if not s.success)
        
        lines = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            f'<testsuite name="{self.name}" tests="{len(self.steps)}" failures="{failures}" time="{self.total_duration_ms / 1000:.3f}">',
        ]
        
        for step in self.steps:
            if step.success:
                lines.append(f'  <testcase name="{step.name}" time="{step.duration_ms / 1000:.3f}"/>')
            else:
                lines.append(f'  <testcase name="{step.name}" time="{step.duration_ms / 1000:.3f}">')
                lines.append(f'    <failure message="{step.error or "Unknown error"}"/>')
                lines.append('  </testcase>')
        
        lines.append('</testsuite>')
        return "\n".join(lines)


class ScenarioRunner:
    """Runs YAML test scenarios against a running game."""
    
    def __init__(self, host: str = "127.0.0.1", port: int = 9876):
        self.host = host
        self.port = port
        self._client: PlaytestClient | None = None
        self._previous_state: dict[str, Any] = {}
    
    async def run_file(self, path: Path) -> ScenarioResult:
        """Run a scenario from a YAML file."""
        with open(path) as f:
            scenario = yaml.safe_load(f)
        
        return await self.run(scenario)
    
    async def run(self, scenario: dict[str, Any]) -> ScenarioResult:
        """Run a scenario definition."""
        name = scenario.get("name", "Unnamed Scenario")
        result = ScenarioResult(name=name, success=True)
        
        import time
        start_time = time.time()
        
        try:
            self._client = PlaytestClient(self.host, self.port)
            await self._client.connect()
            
            # Setup phase
            if "setup" in scenario:
                await self._run_setup(scenario["setup"])
            
            # Run steps
            for step_def in scenario.get("steps", []):
                step_result = await self._run_step(step_def)
                result.steps.append(step_result)
                
                if not step_result.success:
                    result.success = False
                    
                    # Run on_failure if defined
                    if "on_failure" in scenario:
                        await self._run_on_failure(scenario["on_failure"])
                    
                    break
        
        except Exception as e:
            result.success = False
            result.error = str(e)
        
        finally:
            if self._client:
                await self._client.disconnect()
            
            result.total_duration_ms = int((time.time() - start_time) * 1000)
        
        return result
    
    async def _run_setup(self, setup: dict[str, Any]) -> None:
        """Run setup phase."""
        assert self._client is not None
        
        # Load preset if specified
        if "load_preset" in setup:
            # This would require the game to support loading presets
            # For now, just note it
            pass
        
        # Load scenario if specified
        if "load_scenario" in setup:
            await self._client._call("scenario", {"load": setup["load_scenario"]})
    
    async def _run_step(self, step: dict[str, Any]) -> StepResult:
        """Run a single step."""
        assert self._client is not None
        
        import time
        start_time = time.time()
        
        name = step.get("name", "Unnamed Step")
        result = StepResult(name=name, success=True)
        
        try:
            # Get state if requested
            if step.get("get_state"):
                self._previous_state = await self._client.get_state()
                result.state_snapshot = self._previous_state
            
            # Send input
            if "input" in step:
                input_def = step["input"]
                if isinstance(input_def, dict):
                    await self._client.send_input(
                        input_def.get("action", ""),
                        input_def.get("duration_ms", 0),
                    )
                elif isinstance(input_def, str):
                    await self._client.send_input(input_def)
            
            # Call method on node
            if "call_method" in step:
                cm = step["call_method"]
                await self._client.call_method(
                    cm.get("node", ""),
                    cm.get("method", ""),
                    cm.get("args", []),
                )
            
            # Scene change
            if "scene_change" in step:
                sc = step["scene_change"]
                await self._client.scene_change(sc.get("scene", ""))
            
            # Wait (after actions, before assertions)
            if "wait" in step:
                wait_def = step["wait"]
                if isinstance(wait_def, dict):
                    if "condition" in wait_def:
                        wait_result = await self._client.wait_for(
                            wait_def["condition"],
                            wait_def.get("timeout_ms", 5000),
                        )
                        if wait_result.get("timeout"):
                            raise AssertionError(f"Wait condition timed out: {wait_def['condition']}")
                    elif "timeout_ms" in wait_def:
                        await self._client.wait_ms(wait_def["timeout_ms"])
            
            if "wait_ms" in step:
                import asyncio
                await asyncio.sleep(step["wait_ms"] / 1000.0)
            
            # Assertions
            if "assert" in step:
                current_state = await self._client.get_state()
                # Debug: print player state
                if "player" in current_state:
                    pos = current_state.get('player', {}).get('position', {})
                    prev_pos = self._previous_state.get('player', {}).get('position', {}) if self._previous_state else {}
                    print(f"  [DEBUG] current pos: ({pos.get('x')}, {pos.get('y')}), prev pos: ({prev_pos.get('x')}, {prev_pos.get('y')})")
                else:
                    print(f"  [DEBUG] No player in state. State keys: {list(current_state.keys())}")
                for assertion in step["assert"]:
                    if not self._evaluate_assertion(assertion, current_state):
                        raise AssertionError(f"Assertion failed: {assertion}")
            
            # Screenshot
            if "screenshot" in step:
                screenshot_result = await self._client.screenshot()
                result.screenshot = screenshot_result.get("path")
            
            # Repeat
            if "repeat" in step:
                for _ in range(step["repeat"]):
                    for sub_step in step.get("steps", []):
                        sub_result = await self._run_step(sub_step)
                        if not sub_result.success:
                            result.success = False
                            result.error = sub_result.error
                            return result
        
        except Exception as e:
            result.success = False
            result.error = str(e)
        
        result.duration_ms = int((time.time() - start_time) * 1000)
        return result
    
    def _evaluate_assertion(self, assertion: str, state: dict[str, Any]) -> bool:
        """Evaluate an assertion against current state."""
        # Handle $previous references
        assertion = assertion.replace("$previous", "$prev")
        
        # Simple assertion patterns
        if " == " in assertion:
            left, right = assertion.split(" == ", 1)
            left_val = self._get_value(left.strip(), state)
            right_val = self._parse_value(right.strip())
            return left_val == right_val
        
        if " > " in assertion:
            left, right = assertion.split(" > ", 1)
            left_val = self._get_value(left.strip(), state)
            right_val = self._get_value(right.strip(), state) if "$" in right else float(right.strip())
            return left_val > right_val
        
        if " < " in assertion:
            left, right = assertion.split(" < ", 1)
            left_val = self._get_value(left.strip(), state)
            right_val = self._get_value(right.strip(), state) if "$" in right else float(right.strip())
            return left_val < right_val
        
        if " contains " in assertion:
            left, right = assertion.split(" contains ", 1)
            container = self._get_value(left.strip(), state)
            item = self._parse_value(right.strip())
            
            if isinstance(container, list):
                return any(self._matches(i, item) for i in container)
            elif isinstance(container, dict):
                return item in container
            elif isinstance(container, str):
                return item in container
            return False
        
        if " not contains " in assertion:
            left, right = assertion.split(" not contains ", 1)
            container = self._get_value(left.strip(), state)
            item = self._parse_value(right.strip())
            
            if isinstance(container, list):
                return not any(self._matches(i, item) for i in container)
            elif isinstance(container, dict):
                return item not in container
            elif isinstance(container, str):
                return item not in container
            return True
        
        # Boolean check
        val = self._get_value(assertion.strip(), state)
        return bool(val)
    
    def _get_value(self, path: str, state: dict[str, Any]) -> Any:
        """Get a value from state by dotted path."""
        if path.startswith("$prev."):
            path = path[6:]
            state = self._previous_state
        
        parts = path.split(".")
        val: Any = state
        
        for part in parts:
            if isinstance(val, dict):
                val = val.get(part)
            elif isinstance(val, list) and part.isdigit():
                val = val[int(part)]
            else:
                return None
        
        return val
    
    def _parse_value(self, value: str) -> Any:
        """Parse a value from string."""
        # Remove quotes
        if (value.startswith("'") and value.endswith("'")) or \
           (value.startswith('"') and value.endswith('"')):
            return value[1:-1]
        
        # Numbers
        if value.isdigit():
            return int(value)
        
        try:
            return float(value)
        except ValueError:
            pass
        
        # Booleans
        if value.lower() == "true":
            return True
        if value.lower() == "false":
            return False
        
        return value
    
    def _matches(self, item: Any, pattern: Any) -> bool:
        """Check if an item matches a pattern."""
        if isinstance(item, dict) and isinstance(pattern, str):
            # Check if dict has id/name matching pattern
            return item.get("id") == pattern or item.get("name") == pattern
        return item == pattern
    
    async def _run_on_failure(self, on_failure: dict[str, Any]) -> None:
        """Run on_failure handlers."""
        assert self._client is not None
        
        if "screenshot" in on_failure:
            await self._client.screenshot()
        
        if "dump_state" in on_failure:
            state = await self._client.get_state()
            path = Path(on_failure["dump_state"])
            path.write_text(json.dumps(state, indent=2))

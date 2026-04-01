# godot-ai-playtest

**External TCP control for Godot 4.x games — built for AI agents, automation, and CI pipelines.**

[![PyPI version](https://badge.fury.io/py/godot-ai-playtest.svg)](https://pypi.org/project/godot-ai-playtest/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Godot 4.x](https://img.shields.io/badge/Godot-4.x-blue.svg)](https://godotengine.org/)

## What is this?

A TCP server plugin for Godot that exposes your game's state and controls via JSON-RPC, plus a Python client for writing tests and automation scripts.

**You run your game normally. An external process connects and controls it.**

```
┌─────────────────┐     TCP:9876      ┌─────────────────┐
│  Python/AI/CI   │◄──────────────────►│  Your Godot Game │
│  (external)     │    JSON-RPC        │  (with plugin)   │
└─────────────────┘                    └─────────────────┘
```

## Why does this exist?

### The Problem

Godot has great built-in testing with GUT, gdUnit4, and the native `Testing` framework. But they all run **inside** the Godot process. This creates problems:

| Limitation | Why it matters |
|------------|----------------|
| **No external control** | AI agents can't play your game |
| **No CI screenshots** | Can't capture visual state from test runners |
| **No cross-process testing** | Can't test save/load by restarting the game |
| **Tight coupling** | Test code mixed with game code |

### The Solution

godot-ai-playtest runs a TCP server **inside** your game that accepts commands from **outside**. This means:

- ✅ **AI agents can play** — LLMs, RL models, or behavior trees can control the game
- ✅ **CI pipelines work** — GitHub Actions can run scenarios and capture screenshots
- ✅ **True integration tests** — Test save/load by actually restarting the process
- ✅ **Language agnostic** — Python client included, but any language can send JSON-RPC

### Comparison

| Feature | GUT/gdUnit4 | godot-ai-playtest |
|---------|-------------|-------------------|
| Unit tests | ✅ Great | ❌ Not the goal |
| Integration tests | ⚠️ Limited | ✅ Full game control |
| External control | ❌ No | ✅ Yes |
| AI agent support | ❌ No | ✅ Yes |
| CI screenshot capture | ⚠️ Hacky | ✅ Built-in |
| Save/load testing | ⚠️ Hard | ✅ Easy |
| Performance profiling | ❌ No | ✅ Built-in |
| Visual regression | ❌ No | ✅ Built-in |

**Use GUT/gdUnit4 for unit tests. Use godot-ai-playtest for integration tests and AI.**

## Quick Start

### 1. Install the Godot Plugin

Copy `addons/godot_ai_playtest/` to your project and enable it in Project Settings → Plugins.

The server starts automatically when your game runs (port 9876 by default).

### 2. Install the Python Client

```bash
pip install godot-ai-playtest
```

### 3. Connect and Control

```python
import asyncio
from godot_ai_playtest import PlaytestClient

async def main():
    async with PlaytestClient() as client:
        # Check connection
        info = await client.ping()
        print(f"Connected to {info['game_name']} v{info['version']}")
        
        # Get game state
        state = await client.get_state()
        print(f"Player at {state['player']['position']}")
        
        # Send input
        await client.send_input("move_right", duration_ms=500)
        
        # Take screenshot
        await client.screenshot("test_screenshot")

asyncio.run(main())
```

### 4. Or use the CLI

```bash
# Test connection
playtest ping

# Get current state
playtest state

# Run a test scenario
playtest run scenarios/smoke_test.yaml
```

## Features

### State Inspection
```python
state = await client.get_state()
# Returns: player position/health, NPCs, world time, UI state, scene info
```

### Input Simulation
```python
await client.send_input("jump", duration_ms=100)
await client.hold_action("move_right")  # Hold until released
await client.click_at(400, 300)  # Mouse click
```

### Time Control
```python
await client.time_advance(days=3)  # Skip forward
await client.time_set(hour=22)     # Set to 10 PM
await client.time_pause()          # Freeze time
```

### NPC Queries
```python
npcs = await client.get_all_npcs()
iris = await client.get_npc("Iris")
# Returns: position, relationship, mood, dialogue flags, quest state
```

### Save/Load Testing
```python
await client.save_game("test_slot")
# ... do destructive things ...
await client.load_game("test_slot")
# State restored!
```

### Performance Assertions
```python
result = await client.assert_performance(
    min_fps=30,
    max_frame_ms=33,
    max_memory_mb=500
)
if not result['success']:
    print(f"Performance failed: {result['failures']}")
```

### Visual Regression
```python
# Save a baseline (do once)
await client.save_baseline("main_menu")

# Compare against it (in CI)
result = await client.compare_screenshot("main_menu", threshold=0.01)
if not result['match']:
    print(f"Visual diff: {result['difference_ratio']*100:.1f}%")
```

### Input Recording & Playback
```python
await client.start_recording()
# ... play manually or via automation ...
recording = await client.stop_recording(save_to="session.json")

# Replay later
await client.playback(load_from="session.json")
```

### Error Capture
```python
await client.start_error_capture()
# ... run game logic ...
errors = await client.get_captured_errors()
assert len(errors['errors']) == 0, "Runtime errors detected!"
```

## YAML Test Scenarios

```yaml
name: "Complete Smoke Test"
steps:
  - name: "At title screen"
    assert:
      - "scene.name == 'TitleScreen'"
    screenshot: "01_title.png"

  - name: "Start new game"
    call_method:
      node: "/root/TitleScreen"
      method: "_on_new_game_pressed"
    wait_ms: 2000

  - name: "Player can move"
    send_input: "move_right"
    duration_ms: 500
    assert:
      - "player.position.x > 0"

  - name: "Skip to day 5"
    time_advance:
      days: 4
    assert:
      - "world.time.day == 5"

  - name: "Performance is acceptable"
    assert_performance:
      min_fps: 30
      max_memory_mb: 500
```

Run with:
```bash
playtest run smoke_test.yaml
```

## API Reference

### Core
| Method | Description |
|--------|-------------|
| `ping()` | Check connection, get server version |
| `get_state()` | Full game state snapshot |
| `screenshot(name)` | Capture viewport |

### Input
| Method | Description |
|--------|-------------|
| `send_input(action, duration_ms)` | Press action for duration |
| `hold_action(action)` | Hold until `release_action()` |
| `release_action(action)` | Release held action |
| `click_at(x, y, button)` | Mouse click |
| `move_mouse(x, y)` | Move cursor |

### Time
| Method | Description |
|--------|-------------|
| `time_advance(days, hours, minutes)` | Skip forward |
| `time_set(day, hour, minute, season)` | Set specific time |
| `time_pause()` / `time_resume()` | Freeze/unfreeze |

### NPCs
| Method | Description |
|--------|-------------|
| `get_npc(name)` | Get specific NPC state |
| `get_all_npcs()` | Get all NPCs |

### Inventory
| Method | Description |
|--------|-------------|
| `get_inventory()` | Get player items |
| `add_item(item, qty)` | Add to inventory |
| `remove_item(item, qty)` | Remove from inventory |

### Persistence
| Method | Description |
|--------|-------------|
| `save_game(slot)` | Save to slot |
| `load_game(slot)` | Load from slot |
| `list_saves()` | List save files |
| `delete_save(slot)` | Delete save |

### Performance
| Method | Description |
|--------|-------------|
| `get_performance()` | FPS, frame time, memory, objects |
| `assert_performance(...)` | Assert thresholds |

### Visual
| Method | Description |
|--------|-------------|
| `save_baseline(name)` | Save reference screenshot |
| `compare_screenshot(name, threshold)` | Compare against baseline |

### Recording
| Method | Description |
|--------|-------------|
| `start_recording()` | Begin recording inputs |
| `stop_recording(save_to)` | Stop and optionally save |
| `playback(load_from)` | Replay recorded inputs |

### Errors
| Method | Description |
|--------|-------------|
| `start_error_capture()` | Start capturing errors |
| `stop_error_capture()` | Stop capturing |
| `get_captured_errors()` | Get captured errors |

### Scene Control
| Method | Description |
|--------|-------------|
| `scene_change(path)` | Change scene |
| `call_method(node, method, args)` | Call method on node |
| `query_node(path)` | Get node info |

## Configuration

In your Godot project, you can configure the server via `project.godot`:

```ini
[playtest]
enabled=true
port=9876
allowed_hosts=["127.0.0.1"]
```

Or disable in release builds:
```gdscript
# In playtest_server.gd
func _ready():
    if OS.has_feature("release"):
        queue_free()
        return
```

## Use Cases

### AI Agent Playing Your Game
```python
# LLM-based agent
while not game_over:
    state = await client.get_state()
    action = llm.decide(state)  # Your AI logic
    await client.send_input(action)
```

### CI/CD Integration
```yaml
# .github/workflows/playtest.yml
- name: Run playtest
  run: |
    godot --headless --path . &
    sleep 5
    playtest run tests/smoke_test.yaml
```

### Regression Testing
```python
# Save baseline once
await client.save_baseline("inventory_screen")

# In CI, compare
result = await client.compare_screenshot("inventory_screen")
assert result['match'], f"Visual regression: {result['diff_image']}"
```

### Performance Monitoring
```python
# Run complex scenario, then check
await client.time_advance(days=100)  # Stress test
perf = await client.assert_performance(min_fps=30)
assert perf['success'], f"Performance degraded: {perf['failures']}"
```

## Requirements

- **Godot**: 4.x (tested on 4.4+)
- **Python**: 3.10+ (for type hints)
- **OS**: Any (Windows, macOS, Linux)

## Contributing

Issues and PRs welcome! This project uses:
- GDScript for the Godot plugin
- Python with asyncio for the client
- JSON-RPC 2.0 for the protocol

## License

MIT License — see [LICENSE](LICENSE) for details.

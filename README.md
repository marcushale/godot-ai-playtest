# godot-playtest

AI-assisted playtesting framework for Godot 4.x games.

> **Inspired by [GodotTestDriver](https://github.com/chickensoft-games/GodotTestDriver)** patterns for input simulation and wait conditions, adapted for external TCP control.

## Features

- ✅ **External Control** — TCP/JSON-RPC server for AI agents and CI pipelines
- ✅ **State Inspection** — Player position, health, NPCs, world time, UI state
- ✅ **Input Simulation** — Actions, mouse clicks, held inputs (GodotTestDriver patterns)
- ✅ **Screenshots** — Capture viewport for visual verification
- ✅ **Scenarios** — YAML-based test scripts with assertions
- ✅ **Zero Game Changes** — Just add the plugin, no code modifications

## Quick Start

### 1. Install the Godot Plugin

Copy `addons/godot_playtest/` to your project and enable it in Project Settings.

### 2. Install the CLI

```bash
cd cli
python -m venv .venv
source .venv/bin/activate
pip install -e .
```

### 3. Run Tests

```bash
# Start your game
godot --path /path/to/your/game

# Test connection
playtest ping

# Get game state
playtest state

# Run a scenario
playtest run scenarios/smoke_test.yaml
```

## API Methods

| Method | Description |
|--------|-------------|
| `ping` | Check connection, get server version |
| `get_state` | Full game state snapshot |
| `send_input` | Send action with optional duration |
| `hold_action` | Hold action until released |
| `release_action` | Release held action |
| `click_at` | Mouse click at position |
| `move_mouse` | Move mouse to position |
| `screenshot` | Capture viewport |
| `scene_change` | Direct scene transition |
| `call_method` | Call method on any node |
| `query` | Query nodes, entities, tiles |
| `wait_for` | Check condition (client-side wait) |

## Input Simulation

Inspired by GodotTestDriver's proven patterns:

```python
# Tap action (100ms default)
await client.send_input("jump")

# Hold action for duration
await client.send_input("move_right", duration_ms=500)

# Manual hold/release
await client.hold_action("sprint")
# ... later ...
await client.release_action("sprint")

# Mouse control
await client.click_at(640, 360)
await client.move_mouse(100, 200)
```

## Scenario Format

```yaml
name: "Smoke Test"
steps:
  - name: "Check title screen"
    assert:
      - "scene.name == 'TitleScreen'"
    screenshot: "01_title.png"

  - name: "Start game"
    call_method:
      node: "/root/TitleScreen"
      method: "_on_new_game"
    wait_ms: 1000

  - name: "Verify playing"
    assert:
      - "world.game_state == 'PLAYING'"
      - "player.exists == true"
```

## Architecture

```
┌─────────────────┐     TCP:9876      ┌─────────────────┐
│  Python CLI /   │◄──────────────────►│  PlaytestServer │
│  AI Agent       │    JSON-RPC        │  (Godot Plugin) │
└─────────────────┘                    └─────────────────┘
```

- **PlaytestServer** — GDScript autoload, listens on localhost:9876
- **Python Client** — Async client with typed methods
- **Scenario Runner** — YAML parser with assertions and screenshots

## Credits

Input simulation patterns adapted from [GodotTestDriver](https://github.com/chickensoft-games/GodotTestDriver) by [derkork](https://github.com/derkork), maintained by [Chickensoft](https://chickensoft.games).

Key patterns borrowed:
- `Input.parse_input_event()` + `Input.action_press()` + `Input.flush_buffered_events()` for reliable input
- Mouse movement with `InputEventMouseMotion` and proper relative coordinates
- Condition evaluation with timeout handling

## License

MIT

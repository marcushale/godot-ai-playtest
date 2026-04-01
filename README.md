# Godot Playtest

**AI-assisted playtesting for Godot 4 games.**

Give AI agents the ability to see game state, inject inputs, and verify behavior — closing the gap between "tests pass" and "game actually works."

## The Problem

AI coding agents can write game code and run unit tests, but they can't:
- See what's happening in the running game
- Verify that visual elements render correctly
- Test that gameplay *feels* right
- Catch issues that only appear during actual play

Godot Playtest bridges this gap by exposing game state and controls through a simple API.

## Features

- **State Introspection** — Query player position, inventory, NPC states, world time, UI status
- **Input Injection** — Send movement, actions, menu navigation programmatically
- **Screenshot Capture** — Grab frames at specific moments for visual verification
- **Scenario Scripts** — Define repeatable test sequences in YAML
- **Event Streaming** — Subscribe to game events in real-time
- **CI Integration** — Run smoke tests on every commit

## Quick Start

### 1. Add to your Godot project

Copy `addons/godot_playtest/` to your project's `addons/` folder, then enable the plugin in Project Settings.

### 2. Install the CLI

```bash
pip install godot-playtest
```

### 3. Run your game and connect

```bash
# In one terminal, run your game
godot --path /your/project

# In another terminal
playtest state
```

### 4. Start testing

```bash
# Get current game state
playtest state

# Send input
playtest input move_right --duration 500
playtest input interact

# Take a screenshot
playtest screenshot --output frame.png

# Run a test scenario
playtest run scenarios/smoke_test.yaml
```

## Architecture

```
┌─────────────────────────────────────────────┐
│              GODOT GAME                     │
│  ┌───────────────────────────────────────┐  │
│  │     PlaytestServer (Autoload)         │  │
│  │  • TCP socket (localhost:9876)        │  │
│  │  • JSON-RPC 2.0 protocol              │  │
│  │  • Debug builds only                  │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────┐
│           playtest CLI / Library            │
│  • Python 3.10+                             │
│  • Async client                             │
│  • Scenario runner                          │
└─────────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────┐
│              AI Agent                       │
│  • Analyze state JSON                       │
│  • Verify assertions                        │
│  • Review screenshots                       │
└─────────────────────────────────────────────┘
```

## API Reference

### State Query

```bash
playtest state
```

Returns full game state as JSON:

```json
{
  "scene": "res://scenes/main.tscn",
  "player": {
    "position": {"x": 12, "y": 8},
    "state": "idle",
    "inventory": [{"id": "wood", "quantity": 5}]
  },
  "world": {
    "time": {"hour": 14, "day": 3},
    "weather": "clear"
  },
  "npcs": [...],
  "ui": {
    "open_panels": [],
    "dialogue_active": false
  }
}
```

### Input Injection

```bash
# Single action
playtest input move_right --duration 500

# Press and release
playtest input interact

# Sequence
playtest sequence "right:500, wait:100, interact"
```

### Screenshots

```bash
playtest screenshot --output frame.png
```

### Targeted Queries

```bash
# Get specific entity
playtest query entity player
playtest query entity npc_colonist_1

# Get tile info
playtest query tile 12,8

# Get entities near position
playtest query near 12,8 --radius 5
```

### Scenario Scripts

```yaml
# scenarios/test_movement.yaml
name: "Basic Movement Test"

steps:
  - name: "Get starting position"
    get_state: true
    
  - name: "Move right"
    input: {action: "move_right", duration_ms: 500}
    wait: {condition: "player.state == 'idle'", timeout_ms: 2000}
    
  - name: "Verify movement"
    assert:
      - "player.position.x > $previous.player.position.x"
    screenshot: "after_move.png"
```

Run with:
```bash
playtest run scenarios/test_movement.yaml
```

## Integration with Your Game

### Exposing Custom State

Implement `_playtest_get_state()` on any node to include it in state dumps:

```gdscript
# your_custom_manager.gd
func _playtest_get_state() -> Dictionary:
    return {
        "custom_value": my_value,
        "important_flag": is_something_enabled
    }
```

### Custom Events

Emit events that the playtest tool can capture:

```gdscript
PlaytestServer.emit_event("custom_event", {
    "data": "value"
})
```

### Scenario Presets

Define starting states for repeatable tests:

```json
// presets/player_with_tools.json
{
  "player_position": {"x": 10, "y": 10},
  "inventory": [
    {"id": "axe", "quantity": 1},
    {"id": "pickaxe", "quantity": 1}
  ],
  "world_time": {"hour": 8, "day": 1}
}
```

Load in scenarios:
```yaml
setup:
  load_preset: "player_with_tools"
```

## CI Integration

### GitHub Actions Example

```yaml
name: Playtest
on: [push, pull_request]

jobs:
  smoke-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Setup Godot
        uses: chickensoft-games/setup-godot@v1
        with:
          version: 4.2.1
          
      - name: Install playtest CLI
        run: pip install godot-playtest
        
      - name: Run smoke tests
        run: |
          godot --headless --path . &
          sleep 5
          playtest run scenarios/smoke_test.yaml --report junit > results.xml
          
      - name: Upload results
        uses: actions/upload-artifact@v4
        with:
          name: test-results
          path: results.xml
```

## Requirements

- **Godot 4.2+**
- **Python 3.10+**
- Debug build (PlaytestServer is disabled in release builds)

## Security

- Server binds to `localhost` only — no network exposure
- Only active when `OS.is_debug_build()` returns true
- No `execute` method in CI mode (configurable)

## License

MIT License — use it, fork it, improve it.

## Contributing

Issues and PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

---

Built for AI-assisted game development. If you're using AI agents to build Godot games, this tool helps them actually *see* what they're building.

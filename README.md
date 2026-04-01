# godot-playtest

AI-assisted playtesting framework for Godot 4.x games.

> **Inspired by [GodotTestDriver](https://github.com/chickensoft-games/GodotTestDriver)** patterns for input simulation and wait conditions, adapted for external TCP control.

## Features

### Core
- ✅ **External Control** — TCP/JSON-RPC server for AI agents and CI pipelines
- ✅ **State Inspection** — Player position, health, NPCs, world time, UI state
- ✅ **Input Simulation** — Actions, mouse clicks, held inputs (GodotTestDriver patterns)
- ✅ **Screenshots** — Capture viewport for visual verification
- ✅ **Scenarios** — YAML-based test scripts with assertions

### v0.3.0 — New Features
- ✅ **Time Control** — Advance game time by days/hours/minutes
- ✅ **NPC State** — Query NPC position, relationship, dialogue flags, quest state
- ✅ **Save/Load** — Save/load game state, list/delete saves
- ✅ **Performance Metrics** — FPS, frame times, memory, object counts
- ✅ **Performance Assertions** — Fail tests if below thresholds
- ✅ **Error Capture** — Capture errors/warnings during test runs
- ✅ **Record & Playback** — Record inputs, replay for regression testing
- ✅ **Visual Regression** — Compare screenshots against baselines
- ✅ **Inventory** — Get/add/remove items from player inventory

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

### Core
| Method | Description |
|--------|-------------|
| `ping` | Check connection, get server version |
| `get_state` | Full game state snapshot |
| `screenshot` | Capture viewport |

### Input
| Method | Description |
|--------|-------------|
| `send_input` | Send action with duration |
| `hold_action` | Hold action until released |
| `release_action` | Release held action |
| `click_at` | Mouse click at position |
| `move_mouse` | Move mouse to position |

### Time Control
| Method | Description |
|--------|-------------|
| `time_advance` | Advance by days/hours/minutes |
| `time_set` | Set specific time |
| `time_pause` | Pause game time |
| `time_resume` | Resume game time |

### NPC State
| Method | Description |
|--------|-------------|
| `get_npc` | Get specific NPC info |
| `get_all_npcs` | Get all NPCs |

### Inventory
| Method | Description |
|--------|-------------|
| `get_inventory` | Get player inventory |
| `add_item` | Add item to inventory |
| `remove_item` | Remove item from inventory |

### Save/Load
| Method | Description |
|--------|-------------|
| `save_game` | Save to slot |
| `load_game` | Load from slot |
| `list_saves` | List save files |
| `delete_save` | Delete save file |

### Performance
| Method | Description |
|--------|-------------|
| `get_performance` | Get metrics (FPS, memory, etc.) |
| `assert_performance` | Assert min FPS, max frame time, etc. |

### Error Capture
| Method | Description |
|--------|-------------|
| `start_error_capture` | Start capturing errors |
| `stop_error_capture` | Stop capturing |
| `get_captured_errors` | Get captured errors |

### Recording
| Method | Description |
|--------|-------------|
| `start_recording` | Start recording inputs |
| `stop_recording` | Stop and optionally save |
| `playback` | Replay recorded inputs |

### Visual Regression
| Method | Description |
|--------|-------------|
| `save_baseline` | Save current screen as baseline |
| `compare_screenshot` | Compare against baseline |

## Example Usage

### Time Control
```python
# Skip to evening
await client.time_advance(hours=6)

# Set specific time
await client.time_set(day=5, hour=8, season="SUMMER")

# Check crop growth after time skip
await client.time_advance(days=3)
state = await client.get_state()
```

### NPC Interaction
```python
# Get all NPCs
npcs = await client.get_all_npcs()
for npc in npcs['npcs']:
    print(f"{npc['name']}: relationship={npc.get('relationship', 0)}")

# Check specific NPC
iris = await client.get_npc("Iris")
if iris['found']:
    print(f"Iris mood: {iris['npc'].get('mood')}")
```

### Performance Testing
```python
# Get metrics
perf = await client.get_performance()
print(f"FPS: {perf['fps']}, Memory: {perf['memory']['static_mb']}MB")

# Assert thresholds
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
# Save baseline (do once)
await client.save_baseline("main_menu")

# Later: compare against baseline
result = await client.compare_screenshot("main_menu", threshold=0.01)
if not result['match']:
    print(f"Visual diff: {result['difference_ratio']*100:.1f}%")
    print(f"Diff image: {result['diff_image']}")
```

### Recording & Playback
```python
# Record a play session
await client.start_recording()
# ... play the game ...
recording = await client.stop_recording(save_to="user://recordings/session1.json")

# Replay later
await client.playback(load_from="user://recordings/session1.json")
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

  - name: "Performance check"
    assert_performance:
      min_fps: 30
      max_frame_ms: 50

  - name: "Time skip test"
    time_advance:
      days: 3
    assert:
      - "world.time.day == 4"
```

## Architecture

```
┌─────────────────┐     TCP:9876      ┌─────────────────┐
│  Python CLI /   │◄──────────────────►│  PlaytestServer │
│  AI Agent       │    JSON-RPC        │  (Godot Plugin) │
└─────────────────┘                    └─────────────────┘
```

## Credits

Input simulation patterns adapted from [GodotTestDriver](https://github.com/chickensoft-games/GodotTestDriver) by [derkork](https://github.com/derkork), maintained by [Chickensoft](https://chickensoft.games).

## License

MIT

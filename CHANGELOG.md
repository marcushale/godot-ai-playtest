# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-03-31

### Added
- **Time Control** — `time_advance`, `time_set`, `time_pause`, `time_resume` for skipping game time
- **NPC State Inspection** — `get_npc`, `get_all_npcs` to query NPC position, relationship, mood, dialogue flags, quest state
- **Inventory Management** — `get_inventory`, `add_item`, `remove_item` for player inventory
- **Save/Load System** — `save_game`, `load_game`, `list_saves`, `delete_save` for testing persistence
- **Performance Metrics** — `get_performance` returns FPS, frame times, memory usage, object counts
- **Performance Assertions** — `assert_performance` with min_fps, max_frame_ms, max_memory_mb thresholds
- **Error Capture** — `start_error_capture`, `stop_error_capture`, `get_captured_errors` to fail tests on runtime errors
- **Input Recording** — `start_recording`, `stop_recording`, `playback` for recording and replaying input sequences
- **Visual Regression** — `save_baseline`, `compare_screenshot` with pixel diff and threshold support
- **Hold/Release Actions** — `hold_action`, `release_action` for held input states

### Changed
- Improved TimeManager compatibility with different naming conventions
- Enhanced state snapshot with optional include flags (npcs, inventory, performance)

## [0.2.0] - 2026-03-31

### Added
- Reliable input simulation using full event pipeline (InputEventAction + parse_input_event + flush)
- `click_at` and `move_mouse` for mouse input
- `query_node`, `query_entities_near`, `query_tile`, `query_input_actions` for scene inspection
- `scene_change` and `call_method` for scene control
- `wait_for` condition checking
- Comprehensive Python client with async/await support
- YAML scenario format with assertions

### Changed
- Input simulation now properly queues events through Godot's input system
- Improved error handling with JSON-RPC error codes

## [0.1.0] - 2026-03-30

### Added
- Initial release
- TCP server (JSON-RPC 2.0) on port 9876
- Basic state inspection (player position, health, scene info)
- Input simulation via `send_input`
- Screenshot capture
- Python CLI (`playtest ping`, `playtest state`, `playtest run`)
- YAML scenario runner

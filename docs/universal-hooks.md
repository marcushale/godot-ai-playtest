# Universal Hook System

The hook system lets **any node** participate in the playtest API with zero changes to `playtest_server.gd`. Add your node to the `playtest` group, implement one or more `_playtest_*` methods, and it's immediately routable.

---

## Quick Start (5 minutes)

### 1. Add your node to the `playtest` group

The cleanest approach is to self-register in `_ready()`. This keeps the group membership in code rather than the scene file, and only activates in debug builds:

```gdscript
func _ready() -> void:
    if OS.is_debug_build():
        add_to_group("playtest")
```

### 2. Implement one or more hooks

```gdscript
# State snapshot — called by get_system_state / list_systems
func _playtest_get_state() -> Dictionary:
    return {
        "speed": current_speed,
        "level": current_level,
    }

# Action hook — called by call_system {method: "do_something"}
func _playtest_call_do_something(params: Dictionary) -> Dictionary:
    var amount: int = params.get("amount", 1)
    do_something(amount)
    return {"success": true, "amount": amount}

# Setter hook — called by call_system {method: "speed", value: 5.0}
func _playtest_set_speed(value: Variant) -> Dictionary:
    current_speed = float(value)
    return {"success": true, "speed": current_speed}
```

### 3. Use it from Python

```python
# See all registered systems
systems = await client.list_systems()

# Read state
state = await client.get_system_state("MySystem")

# Call an action
result = await client.call_system("MySystem", "do_something", params={"amount": 5})

# Use dot-notation shorthand
result = await client.hook("MySystem.do_something", amount=5)
```

---

## Hook Method Reference

| Method signature | When it's called |
|---|---|
| `_playtest_get_state() -> Dictionary` | `get_system_state`, `list_systems`, dot-notation `.get_state` |
| `_playtest_call_<action>(params: Dictionary) -> Dictionary` | `call_system {method: "<action>"}` |
| `_playtest_set_<prop>(value: Variant) -> Dictionary` | `call_system {method: "<prop>", value: ...}` |
| `_playtest_list_methods() -> Array[String]` | Optional. If absent, methods are auto-detected by scanning `get_method_list()` |
| `_playtest_name() -> String` | Optional. Override the name used to find this system (default: `node.name`) |

### Hook resolution order

When `call_system {system: "X", method: "foo"}` is received, the server tries in order:

1. `_playtest_call_foo(params)` — preferred for actions
2. `_playtest_set_foo(value)` — preferred for simple setters
3. `_playtest_foo()` — bare hook, no arguments (for zero-param actions)

---

## Server API

### `list_systems` → `{count, systems[]}`

Returns all nodes currently in the `playtest` group, their node paths, and advertised methods.

```python
result = await client.list_systems()
# {
#   "count": 3,
#   "systems": [
#     {"name": "weather", "node_path": "/root/Main/WeatherManager",
#      "methods": ["get_state", "call_set_weather"], "has_state": true},
#     ...
#   ]
# }
```

### `discover_hooks` → `{count, nodes[], tip}`

More thorough than `list_systems`. Scans the entire tree (including autoloads) for any node with `_playtest_*` methods, whether or not it's in the group. Useful during development to audit what's available.

```python
result = await client.discover_hooks()
# Each entry has in_playtest_group: true/false
# Nodes missing the group will be listed but won't be routable via call_system
```

### `get_system_state {system}` → `{system, state{}}`

Calls `_playtest_get_state()` on the named system.

```python
result = await client.get_system_state("weather")
# {"system": "weather", "state": {"weather_name": "rain", ...}}
```

### `call_system {system, method, [params|value]}` → hook result

Routes to the appropriate `_playtest_*` hook.

```python
# Action with params dict
result = await client.call_system("weather", "set_weather", params={"weather": "rain"})

# Setter with a value
result = await client.call_system("PlayerStats", "speed", value=8.0)
```

### Dot-notation shorthand

Any unknown method name containing `.` or `/` is automatically routed through the hook system. This lets you skip the `call_system` wrapper entirely:

```python
# These are equivalent:
await client.call_system("weather", "set_weather", params={"weather": "fog"})
await client._call("weather.set_weather", {"weather": "fog"})
await client.hook("weather.set_weather", weather="fog")  # cleanest
```

---

## Real-World Example: WeatherManager

Here's the full implementation used in LOOP. Copy this pattern for any system:

```gdscript
# scripts/systems/weather_manager.gd
extends CanvasLayer

enum WeatherType { CLEAR, RAIN, SNOW, FOG, STORM, HEAT_WAVE }

func _ready() -> void:
    if OS.is_debug_build():
        add_to_group("playtest")
    # ... rest of _ready

# Override display name (optional — defaults to node.name)
func _playtest_name() -> String:
    return "weather"

# State snapshot
func _playtest_get_state() -> Dictionary:
    return {
        "weather_name": _weather_name_for_type(current_weather),
        "weather_type": current_weather,
        "available": ["clear", "rain", "snow", "fog", "storm", "heat_wave"],
    }

# Action hook for set_weather
func _playtest_call_set_weather(params: Dictionary) -> Dictionary:
    var weather: Variant = params.get("weather", null)
    if weather == null:
        return {"error": {"code": -32602, "message": "Missing 'weather' param"}}
    # ... map string → enum, call set_weather(type)
    return {"success": true, "old_weather": old_name, "new_weather": new_name}
```

Python usage:

```python
# Read
state = await client.get_system_state("weather")
print(state["state"]["weather_name"])  # "clear"

# Write via hook
await client.hook("weather.set_weather", weather="storm")

# Write via call_system
await client.call_system("weather", "set_weather", params={"weather": "rain"})
```

---

## When to Use Hooks vs. Custom Server Methods

| Scenario | Recommendation |
|---|---|
| New game system (simple state + a few actions) | ✅ Hooks — zero server changes |
| Complex setup needed (e.g. inventory needs `ResourceDefinition` objects) | Custom server method |
| Cross-game portability needed | ✅ Hooks — work in any Godot game |
| Strongly-typed Python convenience method needed | Custom server + client method |
| Rapid prototyping / exploring a system | ✅ Hooks — iterate in the game code only |

**The 80/20 rule:** most systems need only hooks. Only reach for custom server methods when the hook can't handle the complexity (like LOOP's inventory needing full `ResourceDefinition` objects).

---

## Tips

**`discover_hooks` is your friend during development.** Run it after adding hooks to verify they're being detected:

```python
result = await client.discover_hooks()
for node in result["nodes"]:
    status = "✓" if node["in_playtest_group"] else "missing group!"
    print(f"  {status} {node['name']}: {node['methods']}")
```

**NPC and Player hooks work automatically.** Since NPC and Player already self-register in `_ready()`, you can address individual NPCs by name:

```python
await client.hook("NPC_Iris.get_state")
await client.get_system_state("NPC_Kael")
```

**Name collisions are resolved case-insensitively, stripping underscores and spaces.** `"SaveManager"`, `"save_manager"`, and `"savemanager"` all resolve to the same node.

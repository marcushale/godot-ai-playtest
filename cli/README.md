# godot-ai-playtest

**External TCP control for Godot 4.x games — built for AI agents, automation, and CI pipelines.**

## Installation

```bash
pip install godot-ai-playtest
```

## Quick Start

```python
import asyncio
from godot_ai_playtest import PlaytestClient

async def main():
    async with PlaytestClient() as client:
        # Check connection
        await client.ping()
        
        # Get game state
        state = await client.get_state()
        print(f"Player at {state['player']['position']}")
        
        # Send input
        await client.send_input("move_right", duration_ms=500)

asyncio.run(main())
```

## CLI Usage

```bash
# Test connection
playtest ping

# Get state
playtest state

# Run test scenario
playtest run smoke_test.yaml
```

## Requirements

- Godot 4.x game with the godot-ai-playtest plugin installed
- Python 3.10+

## Full Documentation

See the [GitHub repository](https://github.com/marcushale/godot-ai-playtest) for:
- Complete API reference
- YAML scenario format
- Godot plugin installation
- Examples and use cases

## License

MIT

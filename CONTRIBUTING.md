# Contributing to Godot Playtest

Thanks for your interest in contributing!

## Development Setup

1. Clone the repo:
   ```bash
   git clone https://github.com/marcushale/godot-playtest.git
   cd godot-playtest
   ```

2. Install Python dependencies:
   ```bash
   cd cli
   pip install -e ".[dev]"
   ```

3. Open the example project in Godot:
   ```bash
   godot --path example/
   ```

## Project Structure

```
godot-playtest/
├── addons/godot_playtest/     # Godot plugin (GDScript)
│   ├── plugin.cfg
│   ├── playtest_server.gd     # Main TCP server
│   ├── state_serializer.gd    # Game state → JSON
│   └── input_injector.gd      # Programmatic input
├── cli/                        # Python CLI & library
│   ├── pyproject.toml
│   └── src/godot_playtest/
│       ├── __init__.py
│       ├── client.py          # Async TCP client
│       ├── cli.py             # Click CLI
│       └── scenario.py        # YAML scenario runner
├── example/                    # Example Godot project
│   └── project.godot
├── scenarios/                  # Example test scenarios
│   └── smoke_test.yaml
└── docs/                       # Documentation
    ├── api.md
    ├── scenarios.md
    └── integration.md
```

## Running Tests

### Godot Plugin Tests
```bash
cd example
godot --headless --script res://tests/run_tests.gd
```

### Python CLI Tests
```bash
cd cli
pytest
```

## Code Style

### GDScript
- Follow [GDScript style guide](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html)
- Use static typing everywhere
- Document public functions with docstrings

### Python
- Format with `black`
- Lint with `ruff`
- Type hints required

## Pull Request Process

1. Fork the repo and create a feature branch
2. Write tests for new functionality
3. Update documentation if needed
4. Ensure all tests pass
5. Submit PR with clear description

## Reporting Issues

Include:
- Godot version
- Python version
- Steps to reproduce
- Expected vs actual behavior
- Relevant logs/screenshots

## Questions?

Open a discussion or reach out on Discord.

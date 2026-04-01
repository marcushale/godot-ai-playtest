"""godot-ai-playtest — External TCP control for Godot 4.x games."""

from .client import PlaytestClient, PlaytestError
from .scenario import ScenarioRunner

__version__ = "0.3.0"
__all__ = ["PlaytestClient", "PlaytestError", "ScenarioRunner"]

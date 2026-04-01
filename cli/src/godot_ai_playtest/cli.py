"""CLI for Godot Playtest."""

import asyncio
import json
import sys
from pathlib import Path
from typing import Any

import click
from rich.console import Console
from rich.json import JSON as RichJSON  # noqa: N811
from rich.table import Table

from .client import PlaytestClient, PlaytestError
from .scenario import ScenarioRunner

console = Console()


def run_async(coro: Any) -> Any:
    """Run an async coroutine."""
    return asyncio.get_event_loop().run_until_complete(coro)


@click.group()
@click.option("--host", default="127.0.0.1", help="PlaytestServer host")
@click.option("--port", default=9876, help="PlaytestServer port")
@click.pass_context
def main(ctx: click.Context, host: str, port: int) -> None:
    """Godot Playtest - AI-assisted playtesting CLI."""
    ctx.ensure_object(dict)
    ctx.obj["host"] = host
    ctx.obj["port"] = port


@main.command()
@click.pass_context
def ping(ctx: click.Context) -> None:
    """Check connection to PlaytestServer."""

    async def _ping() -> None:
        try:
            async with PlaytestClient(ctx.obj["host"], ctx.obj["port"]) as client:
                result = await client.ping()
                console.print(
                    f"[green]✓ Connected[/green] - Server version: {result.get('version')}"
                )
        except ConnectionRefusedError:
            console.print(
                "[red]✗ Connection refused[/red] - Is the game running with PlaytestServer?"
            )
            sys.exit(1)
        except Exception as e:
            console.print(f"[red]✗ Error:[/red] {e}")
            sys.exit(1)

    run_async(_ping())


@main.command()
@click.option("--json", "as_json", is_flag=True, help="Output raw JSON")
@click.option("--compact", is_flag=True, help="Compact JSON output")
@click.pass_context
def state(ctx: click.Context, as_json: bool, compact: bool) -> None:
    """Get current game state."""

    async def _state() -> None:
        try:
            async with PlaytestClient(ctx.obj["host"], ctx.obj["port"]) as client:
                result = await client.get_state()

                if as_json:
                    if compact:
                        print(json.dumps(result, separators=(",", ":")))
                    else:
                        print(json.dumps(result, indent=2))
                else:
                    console.print(RichJSON(json.dumps(result)))

        except ConnectionRefusedError:
            console.print("[red]✗ Connection refused[/red]")
            sys.exit(1)
        except PlaytestError as e:
            console.print(f"[red]✗ Error:[/red] {e}")
            sys.exit(1)

    run_async(_state())


@main.command()
@click.argument("action")
@click.option("--duration", "-d", default=0, help="Hold duration in ms")
@click.option("--press/--no-press", default=True, help="Press the action")
@click.option("--release/--no-release", default=True, help="Release the action")
@click.pass_context
def input(ctx: click.Context, action: str, duration: int, press: bool, release: bool) -> None:
    """Send player input."""

    async def _input() -> None:
        try:
            async with PlaytestClient(ctx.obj["host"], ctx.obj["port"]) as client:
                await client.send_input(action, duration, press, release)
                console.print(f"[green]✓ Input sent:[/green] {action}")
                if duration > 0:
                    console.print(f"  Duration: {duration}ms")

        except ConnectionRefusedError:
            console.print("[red]✗ Connection refused[/red]")
            sys.exit(1)
        except PlaytestError as e:
            console.print(f"[red]✗ Error:[/red] {e}")
            sys.exit(1)

    run_async(_input())


@main.command()
@click.argument("sequence")
@click.pass_context
def sequence(ctx: click.Context, sequence: str) -> None:
    """Send input sequence (e.g., "right:500, wait:100, interact")."""

    async def _sequence() -> None:
        try:
            # Parse sequence string
            parts = [p.strip() for p in sequence.split(",")]

            async with PlaytestClient(ctx.obj["host"], ctx.obj["port"]) as client:
                await client.send_sequence(parts)
                console.print(f"[green]✓ Sequence executed:[/green] {len(parts)} actions")

        except ConnectionRefusedError:
            console.print("[red]✗ Connection refused[/red]")
            sys.exit(1)
        except PlaytestError as e:
            console.print(f"[red]✗ Error:[/red] {e}")
            sys.exit(1)

    run_async(_sequence())


@main.command()
@click.option("--output", "-o", type=click.Path(), help="Output file path")
@click.option("--scale", default=1.0, help="Scale factor")
@click.option("--format", "fmt", default="png", type=click.Choice(["png", "jpg"]))
@click.pass_context
def screenshot(ctx: click.Context, output: str | None, scale: float, fmt: str) -> None:
    """Capture a screenshot."""

    async def _screenshot() -> None:
        try:
            async with PlaytestClient(ctx.obj["host"], ctx.obj["port"]) as client:
                result = await client.screenshot(scale=scale, format=fmt)

                path = result.get("path", "")
                width = result.get("width", 0)
                height = result.get("height", 0)

                console.print(f"[green]✓ Screenshot captured:[/green] {width}x{height}")
                console.print(f"  Path: {path}")

                # Copy to output if specified
                if output:
                    import shutil

                    shutil.copy(path, output)
                    console.print(f"  Copied to: {output}")

        except ConnectionRefusedError:
            console.print("[red]✗ Connection refused[/red]")
            sys.exit(1)
        except PlaytestError as e:
            console.print(f"[red]✗ Error:[/red] {e}")
            sys.exit(1)

    run_async(_screenshot())


@main.group()
def query() -> None:
    """Query game state."""
    pass


@query.command(name="entity")
@click.argument("name")
@click.option("--json", "as_json", is_flag=True, help="Output raw JSON")
@click.pass_context
def query_entity(ctx: click.Context, name: str, as_json: bool) -> None:
    """Query entity by name."""

    async def _query() -> None:
        try:
            async with PlaytestClient(ctx.obj["host"], ctx.obj["port"]) as client:
                result = await client.query_entity({"name": name})

                if as_json:
                    print(json.dumps(result, indent=2))
                else:
                    console.print(RichJSON(json.dumps(result)))

        except PlaytestError as e:
            console.print(f"[red]✗ Error:[/red] {e}")
            sys.exit(1)

    run_async(_query())


@query.command(name="tile")
@click.argument("position")
@click.option("--json", "as_json", is_flag=True, help="Output raw JSON")
@click.pass_context
def query_tile(ctx: click.Context, position: str, as_json: bool) -> None:
    """Query tile at position (x,y)."""

    async def _query() -> None:
        try:
            x, y = map(int, position.split(","))

            async with PlaytestClient(ctx.obj["host"], ctx.obj["port"]) as client:
                result = await client.query_tile(x, y)

                if as_json:
                    print(json.dumps(result, indent=2))
                else:
                    console.print(RichJSON(json.dumps(result)))

        except ValueError:
            console.print("[red]✗ Invalid position format.[/red] Use: x,y")
            sys.exit(1)
        except PlaytestError as e:
            console.print(f"[red]✗ Error:[/red] {e}")
            sys.exit(1)

    run_async(_query())


@query.command(name="near")
@click.argument("position")
@click.option("--radius", "-r", default=5.0, help="Search radius")
@click.option("--json", "as_json", is_flag=True, help="Output raw JSON")
@click.pass_context
def query_near(ctx: click.Context, position: str, radius: float, as_json: bool) -> None:
    """Query entities near position (x,y)."""

    async def _query() -> None:
        try:
            x, y = map(float, position.split(","))

            async with PlaytestClient(ctx.obj["host"], ctx.obj["port"]) as client:
                result = await client.query_entities_near(x, y, radius)

                if as_json:
                    print(json.dumps(result, indent=2))
                else:
                    entities = result.get("entities", [])
                    console.print(
                        f"[green]Found {len(entities)} entities within {radius} units[/green]"
                    )

                    if entities:
                        table = Table()
                        table.add_column("Name")
                        table.add_column("Position")
                        table.add_column("Distance")

                        for e in entities:
                            pos = e.get("position", {})
                            table.add_row(
                                e.get("name", "?"),
                                f"({pos.get('x', 0):.1f}, {pos.get('y', 0):.1f})",
                                f"{e.get('distance', 0):.2f}",
                            )

                        console.print(table)

        except ValueError:
            console.print("[red]✗ Invalid position format.[/red] Use: x,y")
            sys.exit(1)
        except PlaytestError as e:
            console.print(f"[red]✗ Error:[/red] {e}")
            sys.exit(1)

    run_async(_query())


@main.command()
@click.argument("scenario_path", type=click.Path(exists=True))
@click.option("--report", type=click.Choice(["text", "json", "junit"]), default="text")
@click.option("--output", "-o", type=click.Path(), help="Report output file")
@click.pass_context
def run(ctx: click.Context, scenario_path: str, report: str, output: str | None) -> None:
    """Run a test scenario."""

    async def _run() -> None:
        try:
            runner = ScenarioRunner(ctx.obj["host"], ctx.obj["port"])
            result = await runner.run_file(Path(scenario_path))

            if report == "json":
                report_str = json.dumps(result.to_dict(), indent=2)
            elif report == "junit":
                report_str = result.to_junit()
            else:
                report_str = result.to_text()

            if output:
                Path(output).write_text(report_str)
                console.print(f"Report written to: {output}")
            else:
                print(report_str)

            # Exit with error if scenario failed
            if not result.success:
                sys.exit(1)

        except Exception as e:
            console.print(f"[red]✗ Error:[/red] {e}")
            sys.exit(1)

    run_async(_run())


@main.command()
@click.argument("event_types", nargs=-1)
@click.pass_context
def events(ctx: click.Context, event_types: tuple[str, ...]) -> None:
    """Watch game events (Ctrl+C to stop)."""

    async def _events() -> None:
        try:
            async with PlaytestClient(ctx.obj["host"], ctx.obj["port"]) as client:
                types = list(event_types) if event_types else ["*"]
                await client.subscribe_events(types)

                console.print(f"[green]Watching events:[/green] {', '.join(types)}")
                console.print("Press Ctrl+C to stop\n")

                def on_event(event_type: str, data: dict[str, Any]) -> None:
                    console.print(f"[yellow]{event_type}[/yellow]: {json.dumps(data)}")

                client.on_event(on_event)

                # Keep running until interrupted
                while True:
                    await asyncio.sleep(0.1)

        except KeyboardInterrupt:
            console.print("\n[dim]Stopped watching events[/dim]")
        except ConnectionRefusedError:
            console.print("[red]✗ Connection refused[/red]")
            sys.exit(1)

    run_async(_events())


if __name__ == "__main__":
    main()

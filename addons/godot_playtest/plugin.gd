@tool
extends EditorPlugin

const AUTOLOAD_NAME = "PlaytestServer"
const AUTOLOAD_PATH = "res://addons/godot_playtest/playtest_server.gd"


func _enter_tree() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	print("[GodotPlaytest] Plugin enabled - PlaytestServer autoload added")


func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
	print("[GodotPlaytest] Plugin disabled - PlaytestServer autoload removed")

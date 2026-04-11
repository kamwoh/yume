extends Node

## Frame Capture — saves viewport screenshots for:
## 1. Claude to "see" the game (development aid)
## 2. Recording training data (world modeling)
##
## Press F12 to capture a screenshot.
## Auto-capture mode: saves every N seconds.

var capture_dir: String = "user://captures/"
var auto_capture: bool = false
var auto_interval: float = 1.0
var frame_count: int = 0
var timer: float = 0.0

func _ready() -> void:
	# Read config from meta.json
	var file := FileAccess.open("res://data/meta.json", FileAccess.READ)
	if file:
		var data = JSON.parse_string(file.get_as_text())
		if data is Dictionary:
			var cap: Dictionary = data.get("capture", {})
			if cap is Dictionary:
				auto_capture = cap.get("auto", false)
				auto_interval = cap.get("interval", 1.0)
				capture_dir = cap.get("directory", capture_dir)

	# Ensure capture directory exists
	DirAccess.make_dir_recursive_absolute(capture_dir)
	print("[Capture] Dir: ", capture_dir, " Auto: ", auto_capture)


func _process(delta: float) -> void:
	if auto_capture:
		timer += delta
		if timer >= auto_interval:
			timer = 0.0
			_capture_frame()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F12:
		_capture_frame()
		print("[Capture] Screenshot saved! Frame: ", frame_count)


func _capture_frame() -> void:
	var viewport := get_viewport()
	if not viewport:
		return

	var img := viewport.get_texture().get_image()
	if not img:
		return

	var filename: String = "frame_%05d.png" % frame_count
	var path: String = capture_dir + filename
	img.save_png(path)
	frame_count += 1


## Get the latest capture path (for external tools to read)
func get_latest_capture() -> String:
	if frame_count == 0:
		return ""
	var filename: String = "frame_%05d.png" % (frame_count - 1)
	return capture_dir + filename

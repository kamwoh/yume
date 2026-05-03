extends Node

## Auto-screenshot helper. Add as a Node child of any scene; after
## `delay_seconds`, captures the viewport, saves PNG to `output_path`,
## and quits the engine. Used for Yume's visual-QA loop — running an
## actual rendered game (not headless) and examining the rendered
## frame.
##
## Add to a scene file:
##   [node name="Capture" type="Node" parent="."]
##   script = ExtResource("res://scripts/engine/capture_helper.gd")
##   delay_seconds = 3.0
##   output_path = "_capture.png"

@export var delay_seconds: float = 3.0
@export var output_path: String = "user://_capture.png"
@export var quit_after: bool = true


func _ready() -> void:
	# Wait, then snapshot, then quit. Visible delay matters: gives the
	# scene time to spawn entities, run a few ticks, animate.
	await get_tree().create_timer(delay_seconds).timeout
	var img: Image = get_viewport().get_texture().get_image()
	if img == null:
		push_warning("Capture: get_image returned null")
		if quit_after:
			get_tree().quit()
		return
	var err: int = img.save_png(output_path)
	if err == OK:
		print("[Capture] saved frame to ", output_path)
	else:
		push_error("[Capture] save_png failed: %d" % err)
	if quit_after:
		get_tree().quit()

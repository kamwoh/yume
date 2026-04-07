extends ColorRect

func fade_out(duration: float = 0.3) -> void:
	var tween = create_tween()
	tween.tween_property(self, "color:a", 1.0, duration)
	await tween.finished

func fade_in(duration: float = 0.3) -> void:
	var tween = create_tween()
	tween.tween_property(self, "color:a", 0.0, duration)
	await tween.finished

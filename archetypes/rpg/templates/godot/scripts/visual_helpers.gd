extends Node

# Visual Helpers — THE visual abstraction layer.
# Everything visual goes through here. To upgrade visuals:
#   1. Place sprite images in res://sprites/ (e.g. res://sprites/characters/kai.png)
#   2. These functions auto-detect and use sprites when available
#   3. Falls back to code-drawn shapes if no sprite exists
#   4. For 3D: replace this file with a 3D version that loads .glb/.gltf models
#
# Naming convention for auto-detection:
#   Characters: res://sprites/characters/{character_id}.png
#   NPCs:       res://sprites/npcs/{npc_name_lowercase}.png
#   Props:      res://sprites/props/{prop_type}.png
#   Enemies:    res://sprites/enemies/{enemy_id}.png


## Try to load a sprite. Returns Sprite2D if found, null if not.
static func _try_sprite(parent: Node2D, path: String, fallback_size: Vector2 = Vector2(32, 32)) -> bool:
	if ResourceLoader.exists(path):
		var tex = load(path)
		if tex is Texture2D:
			var sprite := Sprite2D.new()
			sprite.texture = tex
			sprite.name = "Sprite"
			parent.add_child(sprite)
			return true
	return false


static func create_character_visual(parent: Node2D, color: Color, is_player: bool = false, character_id: String = "") -> void:
	# Try sprite first
	if character_id != "":
		var path: String = "res://sprites/characters/" + character_id + ".png"
		if _try_sprite(parent, path):
			# Add shadow under sprite
			var shadow := ColorRect.new()
			shadow.name = "Shadow"
			shadow.size = Vector2(18, 6)
			shadow.position = Vector2(-9, 8)
			shadow.color = Color(0, 0, 0, 0.3)
			parent.add_child(shadow)
			parent.move_child(shadow, 0)
			return

	# Fallback: code-drawn silhouette
	# Shadow
	var shadow := ColorRect.new()
	shadow.name = "Shadow"
	shadow.size = Vector2(18, 6)
	shadow.position = Vector2(-9, 8)
	shadow.color = Color(0, 0, 0, 0.3)
	parent.add_child(shadow)

	# Body
	var body := ColorRect.new()
	body.name = "Body"
	body.size = Vector2(14, 16)
	body.position = Vector2(-7, -8)
	body.color = color
	parent.add_child(body)

	# Head (slightly lighter)
	var head := ColorRect.new()
	head.name = "Head"
	head.size = Vector2(10, 10)
	head.position = Vector2(-5, -18)
	head.color = Color(color.r + 0.1, color.g + 0.1, color.b + 0.1)
	parent.add_child(head)

	# Hair/hat detail (darker accent on top)
	var hair := ColorRect.new()
	hair.name = "Hair"
	hair.size = Vector2(12, 4)
	hair.position = Vector2(-6, -20)
	hair.color = Color(color.r * 0.6, color.g * 0.6, color.b * 0.6)
	parent.add_child(hair)

	if is_player:
		# Player gets a subtle glow outline
		var glow := ColorRect.new()
		glow.name = "Glow"
		glow.size = Vector2(18, 20)
		glow.position = Vector2(-9, -10)
		glow.color = Color(color.r, color.g, color.b, 0.15)
		parent.add_child(glow)
		glow.z_index = -1

static func create_npc_visual(parent: Node2D, color: Color, npc_type: String = "default", npc_name: String = "") -> void:
	# Try sprite first
	if npc_name != "":
		var safe_name = npc_name.to_lower().replace(" ", "_")
		var path: String = "res://sprites/npcs/" + safe_name + ".png"
		if _try_sprite(parent, path):
			return
	if npc_type != "default":
		var path2: String = "res://sprites/npcs/" + npc_type + ".png"
		if _try_sprite(parent, path2):
			return
	# Fallback: code-drawn NPC
	"""Create an NPC silhouette with type-specific details."""
	# Shadow
	var shadow := ColorRect.new()
	shadow.size = Vector2(16, 5)
	shadow.position = Vector2(-8, 8)
	shadow.color = Color(0, 0, 0, 0.25)
	parent.add_child(shadow)

	# Body
	var body := ColorRect.new()
	body.size = Vector2(12, 14)
	body.position = Vector2(-6, -6)
	body.color = color
	parent.add_child(body)

	# Head
	var head := ColorRect.new()
	head.size = Vector2(9, 9)
	head.position = Vector2(-4, -15)
	head.color = Color(color.r + 0.08, color.g + 0.08, color.b + 0.08)
	parent.add_child(head)

	# Type-specific details
	match npc_type:
		"guard":
			# Helmet
			var helmet := ColorRect.new()
			helmet.size = Vector2(11, 4)
			helmet.position = Vector2(-5, -17)
			helmet.color = Color(0.5, 0.5, 0.55)
			parent.add_child(helmet)
			# Spear
			var spear := ColorRect.new()
			spear.size = Vector2(2, 22)
			spear.position = Vector2(7, -18)
			spear.color = Color(0.6, 0.55, 0.4)
			parent.add_child(spear)
		"merchant":
			# Apron
			var apron := ColorRect.new()
			apron.size = Vector2(14, 8)
			apron.position = Vector2(-7, -2)
			apron.color = Color(0.8, 0.75, 0.6)
			parent.add_child(apron)
		"child":
			# Smaller body
			body.size = Vector2(8, 10)
			body.position = Vector2(-4, -2)
			head.size = Vector2(8, 8)
			head.position = Vector2(-4, -10)
		"noble":
			# Cape
			var cape := ColorRect.new()
			cape.size = Vector2(16, 12)
			cape.position = Vector2(-8, -4)
			cape.color = Color(color.r * 0.7, color.g * 0.3, color.b * 0.3, 0.7)
			parent.add_child(cape)
			cape.z_index = -1

static func create_chest_visual(parent: Node2D, opened: bool = false) -> void:
	"""Create a treasure chest that looks like a chest."""
	# Shadow
	var shadow := ColorRect.new()
	shadow.size = Vector2(20, 5)
	shadow.position = Vector2(-10, 6)
	shadow.color = Color(0, 0, 0, 0.25)
	parent.add_child(shadow)

	# Base
	var base := ColorRect.new()
	base.size = Vector2(18, 10)
	base.position = Vector2(-9, -4)
	base.color = Color(0.55, 0.4, 0.15) if not opened else Color(0.35, 0.25, 0.1)
	parent.add_child(base)

	# Lid (angled for closed, flat for open)
	var lid := ColorRect.new()
	lid.size = Vector2(18, 6)
	lid.position = Vector2(-9, -10)
	lid.color = Color(0.7, 0.55, 0.2) if not opened else Color(0.4, 0.3, 0.12)
	parent.add_child(lid)

	# Lock/clasp
	var lock := ColorRect.new()
	lock.size = Vector2(4, 4)
	lock.position = Vector2(-2, -6)
	lock.color = Color(0.8, 0.7, 0.2) if not opened else Color(0.4, 0.35, 0.15)
	parent.add_child(lock)

	if not opened:
		# Sparkle indicator
		var sparkle := ColorRect.new()
		sparkle.size = Vector2(3, 3)
		sparkle.position = Vector2(4, -12)
		sparkle.color = Color(1, 0.95, 0.5, 0.8)
		parent.add_child(sparkle)

static func create_exit_marker(parent: Node2D, label_text: String) -> void:
	"""Create a visible exit marker with arrow."""
	# Glowing pillar
	var pillar := ColorRect.new()
	pillar.size = Vector2(8, 30)
	pillar.position = Vector2(-4, -18)
	pillar.color = Color(0.2, 0.6, 0.9, 0.5)
	parent.add_child(pillar)

	# Arrow head (pointing up, made of 3 rects)
	var arrow1 := ColorRect.new()
	arrow1.size = Vector2(16, 3)
	arrow1.position = Vector2(-8, -20)
	arrow1.color = Color(0.3, 0.8, 1.0, 0.8)
	parent.add_child(arrow1)

	var arrow2 := ColorRect.new()
	arrow2.size = Vector2(10, 3)
	arrow2.position = Vector2(-5, -23)
	arrow2.color = Color(0.3, 0.8, 1.0, 0.7)
	parent.add_child(arrow2)

	var arrow3 := ColorRect.new()
	arrow3.size = Vector2(4, 3)
	arrow3.position = Vector2(-2, -26)
	arrow3.color = Color(0.3, 0.8, 1.0, 0.6)
	parent.add_child(arrow3)

	# Label
	var lbl := Label.new()
	lbl.text = label_text
	lbl.position = Vector2(-40, -38)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(0.3, 0.8, 1.0))
	parent.add_child(lbl)

	# Base glow
	var glow := ColorRect.new()
	glow.size = Vector2(20, 4)
	glow.position = Vector2(-10, 10)
	glow.color = Color(0.2, 0.6, 0.9, 0.3)
	parent.add_child(glow)

static func create_prop_visual(parent: Node2D, prop_type: String, base_c: Color) -> void:
	# Try sprite first
	var path: String = "res://sprites/props/" + prop_type + ".png"
	if _try_sprite(parent, path):
		return
	# Fallback: code-drawn prop
	"""Create a prop with better visual detail."""
	# Shadow for all props
	var shadow := ColorRect.new()
	shadow.size = Vector2(14, 4)
	shadow.position = Vector2(-7, 6)
	shadow.color = Color(0, 0, 0, 0.2)
	parent.add_child(shadow)

	match prop_type:
		"tree", "gnarled_tree":
			# Trunk
			var trunk := ColorRect.new()
			trunk.size = Vector2(6, 18)
			trunk.position = Vector2(-3, -6)
			trunk.color = Color(base_c.r * 0.5, base_c.g * 0.35, base_c.b * 0.25)
			parent.add_child(trunk)
			# Canopy layers (bushy look)
			for i in range(4):
				var leaf := ColorRect.new()
				var w: float = 18 - i * 3
				leaf.size = Vector2(w, 7)
				leaf.position = Vector2(-w / 2, -24 + i * 5)
				var v: float = randf_range(-0.04, 0.04)
				leaf.color = Color(base_c.r + v, base_c.g + v, base_c.b + v, 0.9)
				parent.add_child(leaf)
		"fountain":
			# Base (octagon approximation)
			var base_shape := ColorRect.new()
			base_shape.size = Vector2(28, 6)
			base_shape.position = Vector2(-14, 0)
			base_shape.color = Color(0.45, 0.45, 0.5)
			parent.add_child(base_shape)
			var base2 := ColorRect.new()
			base2.size = Vector2(24, 16)
			base2.position = Vector2(-12, -10)
			base2.color = Color(0.4, 0.4, 0.45)
			parent.add_child(base2)
			# Water
			var water := ColorRect.new()
			water.size = Vector2(20, 12)
			water.position = Vector2(-10, -8)
			water.color = Color(0.25, 0.45, 0.75, 0.7)
			parent.add_child(water)
			# Center pillar
			var pillar := ColorRect.new()
			pillar.size = Vector2(4, 14)
			pillar.position = Vector2(-2, -16)
			pillar.color = Color(0.55, 0.55, 0.6)
			parent.add_child(pillar)
			# Water spray (small dots)
			for i in range(3):
				var spray := ColorRect.new()
				spray.size = Vector2(2, 2)
				spray.position = Vector2(-3 + i * 3, -18 - i)
				spray.color = Color(0.5, 0.7, 0.9, 0.6)
				parent.add_child(spray)
		"torch":
			# Wall mount
			var mount := ColorRect.new()
			mount.size = Vector2(6, 3)
			mount.position = Vector2(-3, -2)
			mount.color = Color(0.35, 0.25, 0.15)
			parent.add_child(mount)
			# Pole
			var pole := ColorRect.new()
			pole.size = Vector2(3, 14)
			pole.position = Vector2(-1, -14)
			pole.color = Color(0.4, 0.3, 0.2)
			parent.add_child(pole)
			# Flame (warm gradient)
			var flame1 := ColorRect.new()
			flame1.size = Vector2(8, 8)
			flame1.position = Vector2(-4, -20)
			flame1.color = Color(1.0, 0.6, 0.1, 0.9)
			parent.add_child(flame1)
			var flame2 := ColorRect.new()
			flame2.size = Vector2(5, 5)
			flame2.position = Vector2(-2, -22)
			flame2.color = Color(1.0, 0.85, 0.3, 0.8)
			parent.add_child(flame2)
			# Glow circle
			var glow := ColorRect.new()
			glow.size = Vector2(20, 20)
			glow.position = Vector2(-10, -26)
			glow.color = Color(1.0, 0.7, 0.2, 0.08)
			parent.add_child(glow)
			glow.z_index = -1
		"barrel":
			var body := ColorRect.new()
			body.size = Vector2(12, 14)
			body.position = Vector2(-6, -8)
			body.color = base_c
			parent.add_child(body)
			# Bands
			for i in range(2):
				var band := ColorRect.new()
				band.size = Vector2(14, 2)
				band.position = Vector2(-7, -6 + i * 8)
				band.color = Color(0.35, 0.35, 0.4)
				parent.add_child(band)
		"crate":
			var body := ColorRect.new()
			body.size = Vector2(14, 14)
			body.position = Vector2(-7, -8)
			body.color = base_c
			parent.add_child(body)
			# Cross
			var h := ColorRect.new()
			h.size = Vector2(14, 1)
			h.position = Vector2(-7, -1)
			h.color = Color(base_c.r * 0.65, base_c.g * 0.65, base_c.b * 0.65)
			parent.add_child(h)
			var v := ColorRect.new()
			v.size = Vector2(1, 14)
			v.position = Vector2(0, -8)
			v.color = Color(base_c.r * 0.65, base_c.g * 0.65, base_c.b * 0.65)
			parent.add_child(v)
		"rock":
			var r1 := ColorRect.new()
			r1.size = Vector2(18, 10)
			r1.position = Vector2(-9, -4)
			r1.color = base_c
			parent.add_child(r1)
			var r2 := ColorRect.new()
			r2.size = Vector2(12, 8)
			r2.position = Vector2(-4, -10)
			r2.color = Color(base_c.r * 0.85, base_c.g * 0.85, base_c.b * 0.85)
			parent.add_child(r2)
			# Highlight
			var hl := ColorRect.new()
			hl.size = Vector2(4, 2)
			hl.position = Vector2(-2, -9)
			hl.color = Color(base_c.r * 1.2, base_c.g * 1.2, base_c.b * 1.2, 0.5)
			parent.add_child(hl)
		"mushroom":
			var stem := ColorRect.new()
			stem.size = Vector2(4, 7)
			stem.position = Vector2(-2, -2)
			stem.color = Color(0.85, 0.8, 0.7)
			parent.add_child(stem)
			var cap := ColorRect.new()
			cap.size = Vector2(12, 7)
			cap.position = Vector2(-6, -9)
			cap.color = base_c
			parent.add_child(cap)
			# Spots
			var spot := ColorRect.new()
			spot.size = Vector2(2, 2)
			spot.position = Vector2(-2, -8)
			spot.color = Color(base_c.r + 0.2, base_c.g + 0.2, base_c.b + 0.2)
			parent.add_child(spot)
		"sign":
			var post := ColorRect.new()
			post.size = Vector2(3, 18)
			post.position = Vector2(-1, -8)
			post.color = Color(0.4, 0.3, 0.2)
			parent.add_child(post)
			var board := ColorRect.new()
			board.size = Vector2(20, 12)
			board.position = Vector2(-10, -20)
			board.color = Color(0.55, 0.45, 0.25)
			parent.add_child(board)
			# Border
			var border := ColorRect.new()
			border.size = Vector2(22, 14)
			border.position = Vector2(-11, -21)
			border.color = Color(0.35, 0.25, 0.15)
			parent.add_child(border)
			border.z_index = -1
		"bench":
			var seat := ColorRect.new()
			seat.size = Vector2(24, 4)
			seat.position = Vector2(-12, -4)
			seat.color = base_c
			parent.add_child(seat)
			var back := ColorRect.new()
			back.size = Vector2(24, 6)
			back.position = Vector2(-12, -10)
			back.color = Color(base_c.r * 0.8, base_c.g * 0.8, base_c.b * 0.8)
			parent.add_child(back)
			var leg1 := ColorRect.new()
			leg1.size = Vector2(2, 6)
			leg1.position = Vector2(-10, -1)
			leg1.color = Color(base_c.r * 0.6, base_c.g * 0.6, base_c.b * 0.6)
			parent.add_child(leg1)
			var leg2 := ColorRect.new()
			leg2.size = Vector2(2, 6)
			leg2.position = Vector2(8, -1)
			leg2.color = Color(base_c.r * 0.6, base_c.g * 0.6, base_c.b * 0.6)
			parent.add_child(leg2)
		"stage":
			var floor_r := ColorRect.new()
			floor_r.size = Vector2(60, 4)
			floor_r.position = Vector2(-30, 0)
			floor_r.color = base_c
			parent.add_child(floor_r)
			var platform := ColorRect.new()
			platform.size = Vector2(56, 26)
			platform.position = Vector2(-28, -26)
			platform.color = Color(base_c.r * 0.9, base_c.g * 0.9, base_c.b * 0.9)
			parent.add_child(platform)
			# Curtain sides
			var curtain_l := ColorRect.new()
			curtain_l.size = Vector2(6, 30)
			curtain_l.position = Vector2(-30, -28)
			curtain_l.color = Color(0.6, 0.15, 0.15)
			parent.add_child(curtain_l)
			var curtain_r := ColorRect.new()
			curtain_r.size = Vector2(6, 30)
			curtain_r.position = Vector2(24, -28)
			curtain_r.color = Color(0.6, 0.15, 0.15)
			parent.add_child(curtain_r)
		_:
			# Default — simple colored rect with border
			var border := ColorRect.new()
			border.size = Vector2(14, 14)
			border.position = Vector2(-7, -7)
			border.color = Color(base_c.r * 0.6, base_c.g * 0.6, base_c.b * 0.6)
			parent.add_child(border)
			var inner := ColorRect.new()
			inner.size = Vector2(12, 12)
			inner.position = Vector2(-6, -6)
			inner.color = base_c
			parent.add_child(inner)

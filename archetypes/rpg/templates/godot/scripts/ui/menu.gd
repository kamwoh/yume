extends PanelContainer

var is_open: bool = false

func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	if UITheme:
		UITheme.style_panel(self)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("menu"):
		if is_open:
			close_menu()
		else:
			open_menu()
		get_viewport().set_input_as_handled()

func open_menu() -> void:
	if DialogueManager.is_playing:
		return
	if BattleManager.in_battle:
		return
	is_open = true
	visible = true
	get_tree().paused = true

	# Populate menu content
	_refresh()

func close_menu() -> void:
	is_open = false
	visible = false
	get_tree().paused = false

func _refresh() -> void:
	for child in get_children():
		child.queue_free()

	var scroll := ScrollContainer.new()
	scroll.layout_mode = 2
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 4)
	scroll.add_child(vbox)

	# Title
	if UITheme:
		vbox.add_child(UITheme.styled_title("MENU"))
	else:
		var title := Label.new()
		title.text = "= MENU ="
		title.add_theme_font_size_override("font_size", 24)
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(title)

	# --- Party ---
	if UITheme:
		vbox.add_child(UITheme.styled_header("Party"))
	else:
		var h := Label.new()
		h.text = "--- Party ---"
		vbox.add_child(h)

	for m in PartyManager.party:
		var card := PanelContainer.new()
		if UITheme:
			UITheme.style_panel(card)
		var card_vbox := VBoxContainer.new()
		card_vbox.add_theme_constant_override("separation", 2)
		card.add_child(card_vbox)

		if UITheme:
			card_vbox.add_child(UITheme.styled_label(
				"%s  Lv.%d  [%s]" % [m["name"], m["level"], m["class"]],
				UITheme.FONT_SIZE_BODY, UITheme.ACCENT
			))
		else:
			var n := Label.new()
			n.text = "%s Lv.%d %s" % [m["name"], m["level"], m["class"]]
			card_vbox.add_child(n)

		# HP/MP bars
		if UITheme:
			var bars := HBoxContainer.new()
			bars.add_theme_constant_override("separation", 6)

			var hp_lbl := UITheme.styled_label("HP", UITheme.FONT_SIZE_SMALL)
			bars.add_child(hp_lbl)
			bars.add_child(UITheme.hp_bar(m["hp"], m["max_hp"]))

			var mp_lbl := UITheme.styled_label("MP", UITheme.FONT_SIZE_SMALL)
			bars.add_child(mp_lbl)
			bars.add_child(UITheme.mp_bar(m["mp"], m["max_mp"]))
			card_vbox.add_child(bars)

		# Stats row
		if UITheme:
			card_vbox.add_child(UITheme.styled_label(
				"STR:%d  MAG:%d  DEF:%d  SPR:%d  SPD:%d" % [
					m["strength"], m["magic"], m["defense"], m["spirit"], m["speed"]
				], UITheme.FONT_SIZE_SMALL, UITheme.TEXT_DIM
			))

		vbox.add_child(card)

	# --- Inventory ---
	if UITheme:
		vbox.add_child(UITheme.styled_header("Inventory"))
	else:
		var inv_h := Label.new()
		inv_h.text = "--- Inventory ---"
		vbox.add_child(inv_h)

	for slot in InventoryManager.items:
		var data = InventoryManager.get_item_data(slot["id"])
		if UITheme:
			vbox.add_child(UITheme.styled_label(
				"%s  x%d" % [data.get("name", slot["id"]), slot["qty"]],
				UITheme.FONT_SIZE_BODY
			))
		else:
			var l := Label.new()
			l.text = "%s x%d" % [data.get("name", slot["id"]), slot["qty"]]
			vbox.add_child(l)

	# Gil
	var gil_label := Label.new()
	gil_label.text = "\nGil: " + str(GameManager.gil)
	gil_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(gil_label)

	# --- Save/Load ---
	if UITheme:
		vbox.add_child(UITheme.styled_header("Save / Load"))

	var save_row := HBoxContainer.new()
	save_row.add_theme_constant_override("separation", 8)
	for slot_idx in range(3):
		var slot_num: int = slot_idx
		var has_save: bool = SaveManager.has_save(slot_num)

		var save_btn := Button.new()
		save_btn.text = "Save " + str(slot_num + 1)
		save_btn.pressed.connect(func():
			SaveManager.save_game(slot_num)
			DialogueManager.show_simple_message("", "Game saved to slot " + str(slot_num + 1) + "!")
			close_menu()
		)
		if UITheme: UITheme.style_button(save_btn)
		save_row.add_child(save_btn)

		var load_btn := Button.new()
		load_btn.text = "Load " + str(slot_num + 1)
		load_btn.disabled = not has_save
		load_btn.pressed.connect(func():
			close_menu()
			SaveManager.load_game(slot_num)
		)
		if UITheme: UITheme.style_button(load_btn)
		save_row.add_child(load_btn)
	vbox.add_child(save_row)

	# Controls hint
	var hint := Label.new()
	hint.text = "\n[ESC to close]"
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	vbox.add_child(hint)

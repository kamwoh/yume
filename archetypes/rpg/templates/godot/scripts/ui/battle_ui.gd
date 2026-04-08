extends CanvasLayer

# Battle UI — shows during combat, hidden during exploration
# Layout: party status (left), enemies (right), command menu (bottom-left), log (bottom-right)

var battle_panel: PanelContainer
var party_container: VBoxContainer
var enemy_container: VBoxContainer
var command_panel: PanelContainer
var command_buttons: VBoxContainer
var battle_log: RichTextLabel
var victory_panel: PanelContainer

var party_bars: Dictionary = {}  # id -> {hp_bar, mp_bar, atb_bar, name_label}
var enemy_bars: Dictionary = {}  # index -> {hp_bar, name_label}

func _ready() -> void:
	layer = 20
	visible = false

	BattleManager.battle_started.connect(_on_battle_started)
	BattleManager.battle_ended.connect(_on_battle_ended)
	BattleManager.combatant_ready.connect(_on_combatant_ready)
	BattleManager.combatant_acted.connect(_on_combatant_acted)
	BattleManager.combatant_defeated.connect(_on_combatant_defeated)

	_build_ui()

func _build_ui() -> void:
	# Full-screen dark background
	var bg := ColorRect.new()
	bg.name = "BattleBG"
	bg.color = Color(0.03, 0.03, 0.08, 0.95)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# Main container
	var main := VBoxContainer.new()
	main.name = "Main"
	main.set_anchors_preset(Control.PRESET_FULL_RECT)
	main.anchor_left = 0.02
	main.anchor_right = 0.98
	main.anchor_top = 0.02
	main.anchor_bottom = 0.98
	add_child(main)

	# Top row: party (left) vs enemies (right)
	var top_row := HBoxContainer.new()
	top_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	top_row.add_theme_constant_override("separation", 40)
	main.add_child(top_row)

	# Party panel
	var party_panel := PanelContainer.new()
	party_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if UITheme: UITheme.style_panel(party_panel)
	top_row.add_child(party_panel)
	party_container = VBoxContainer.new()
	party_container.add_theme_constant_override("separation", 8)
	party_panel.add_child(party_container)

	# Enemy panel
	var enemy_panel := PanelContainer.new()
	enemy_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if UITheme: UITheme.style_panel(enemy_panel)
	top_row.add_child(enemy_panel)
	enemy_container = VBoxContainer.new()
	enemy_container.add_theme_constant_override("separation", 8)
	enemy_panel.add_child(enemy_container)

	# Bottom row: commands (left) + battle log (right)
	var bottom_row := HBoxContainer.new()
	bottom_row.custom_minimum_size = Vector2(0, 180)
	bottom_row.add_theme_constant_override("separation", 20)
	main.add_child(bottom_row)

	# Command panel
	command_panel = PanelContainer.new()
	command_panel.custom_minimum_size = Vector2(200, 0)
	command_panel.visible = false
	if UITheme: UITheme.style_panel(command_panel)
	bottom_row.add_child(command_panel)
	command_buttons = VBoxContainer.new()
	command_buttons.add_theme_constant_override("separation", 4)
	command_panel.add_child(command_buttons)

	# Battle log
	var log_panel := PanelContainer.new()
	log_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if UITheme: UITheme.style_panel(log_panel)
	bottom_row.add_child(log_panel)
	battle_log = RichTextLabel.new()
	battle_log.bbcode_enabled = true
	battle_log.scroll_following = true
	battle_log.fit_content = false
	if UITheme:
		battle_log.add_theme_color_override("default_color", UITheme.TEXT_COLOR)
		battle_log.add_theme_font_size_override("normal_font_size", UITheme.FONT_SIZE_SMALL)
	log_panel.add_child(battle_log)

	# Victory panel (hidden)
	victory_panel = PanelContainer.new()
	victory_panel.visible = false
	victory_panel.set_anchors_preset(Control.PRESET_CENTER)
	victory_panel.custom_minimum_size = Vector2(300, 150)
	if UITheme: UITheme.style_panel(victory_panel)
	add_child(victory_panel)

func _on_battle_started() -> void:
	visible = true
	battle_log.clear()
	_log("Battle start!")
	_refresh_party()
	_refresh_enemies()
	command_panel.visible = false
	victory_panel.visible = false

	# Hide exploration UI
	var hud = get_tree().current_scene.get_node_or_null("UI/HUD")
	if hud: hud.visible = false
	var player = get_tree().current_scene.get_node_or_null("Player")
	if player: player.visible = false
	var loc_root = get_tree().current_scene.get_node_or_null("LocationRoot")
	if loc_root: loc_root.visible = false

func _on_battle_ended(victory: bool) -> void:
	command_panel.visible = false

	if victory:
		var total_xp: int = 0
		var total_gil: int = 0
		for e in BattleManager.enemy_combatants:
			total_xp += e.get("xp_reward", 0)
			total_gil += e.get("gil_reward", 0)
		_log("[color=yellow]Victory![/color] +" + str(total_xp) + " XP, +" + str(total_gil) + " Gil")

		# Show victory panel
		for child in victory_panel.get_children():
			child.queue_free()
		var vbox := VBoxContainer.new()
		victory_panel.add_child(vbox)
		if UITheme:
			vbox.add_child(UITheme.styled_title("Victory!"))
			vbox.add_child(UITheme.styled_label("+" + str(total_xp) + " XP", UITheme.FONT_SIZE_BODY, UITheme.ACCENT))
			vbox.add_child(UITheme.styled_label("+" + str(total_gil) + " Gil", UITheme.FONT_SIZE_BODY))
		else:
			var lbl := Label.new()
			lbl.text = "Victory! +" + str(total_xp) + " XP, +" + str(total_gil) + " Gil"
			vbox.add_child(lbl)
		var cont_btn := Button.new()
		cont_btn.text = "Continue"
		cont_btn.pressed.connect(_close_battle)
		if UITheme: UITheme.style_button(cont_btn)
		vbox.add_child(cont_btn)
		victory_panel.visible = true
	else:
		_log("[color=red]Defeat...[/color]")
		# Simple: just close battle (TODO: game over screen)
		await get_tree().create_timer(2.0).timeout
		_close_battle()

func _close_battle() -> void:
	visible = false
	victory_panel.visible = false

	# Show exploration UI again
	var hud = get_tree().current_scene.get_node_or_null("UI/HUD")
	if hud: hud.visible = true
	var player = get_tree().current_scene.get_node_or_null("Player")
	if player:
		player.visible = true
		player.can_move = true
	var loc_root = get_tree().current_scene.get_node_or_null("LocationRoot")
	if loc_root: loc_root.visible = true

func _on_combatant_ready(combatant: Dictionary) -> void:
	_log("[color=cyan]" + combatant["name"] + "'s turn![/color]")
	_show_commands(combatant)
	_refresh_party()

func _on_combatant_acted(combatant: Dictionary, action: String, target: Dictionary, damage: int) -> void:
	var dmg_text: String
	if damage < 0:
		dmg_text = "[color=green]+" + str(-damage) + " HP[/color]"
	elif damage > 0:
		dmg_text = "[color=red]" + str(damage) + " dmg[/color]"
	else:
		dmg_text = ""
	_log(combatant["name"] + " → " + action + " → " + target["name"] + " " + dmg_text)
	_refresh_party()
	_refresh_enemies()

func _on_combatant_defeated(combatant: Dictionary) -> void:
	_log("[color=gray]" + combatant["name"] + " defeated![/color]")

func _show_commands(combatant: Dictionary) -> void:
	command_panel.visible = true
	for child in command_buttons.get_children():
		child.queue_free()

	# Header
	if UITheme:
		command_buttons.add_child(UITheme.styled_label(combatant["name"], UITheme.FONT_SIZE_BODY, UITheme.ACCENT))
	else:
		var hdr := Label.new()
		hdr.text = combatant["name"]
		command_buttons.add_child(hdr)

	# Attack
	var atk_btn := Button.new()
	atk_btn.text = "Attack"
	atk_btn.pressed.connect(func():
		command_panel.visible = false
		var target: Dictionary = BattleManager._first_alive_enemy()
		if not target.is_empty():
			BattleManager.execute_attack(target)
	)
	if UITheme: UITheme.style_button(atk_btn)
	command_buttons.add_child(atk_btn)

	# Magic (if has MP)
	if combatant["mp"] > 0:
		# Load character abilities from data
		var char_data: Dictionary = {}
		for ch in PartyManager.all_characters.values():
			if ch["id"] == combatant["id"]:
				char_data = ch
				break
		var abilities: Array = char_data.get("abilities", [])
		if abilities.size() > 0:
			for ability in abilities:
				var mp_cost: int = ability.get("mp_cost", 0)
				var aname: String = ability.get("name", "Spell")
				var btn := Button.new()
				btn.text = aname + " (" + str(mp_cost) + " MP)"
				btn.disabled = combatant["mp"] < mp_cost
				var captured_ability: Dictionary = ability
				btn.pressed.connect(func():
					command_panel.visible = false
					BattleManager.execute_ability(captured_ability)
				)
				if UITheme: UITheme.style_button(btn)
				command_buttons.add_child(btn)

	# Item
	var item_btn := Button.new()
	item_btn.text = "Item"
	item_btn.pressed.connect(func():
		# Use first consumable
		for slot in InventoryManager.items:
			var idata: Dictionary = InventoryManager.get_item_data(slot["id"])
			if idata.get("item_type") == "consumable" and idata.get("heal_amount", 0) > 0:
				command_panel.visible = false
				BattleManager.execute_item(slot["id"])
				return
		_log("[color=gray]No usable items![/color]")
	)
	if UITheme: UITheme.style_button(item_btn)
	command_buttons.add_child(item_btn)

	# Defend
	var def_btn := Button.new()
	def_btn.text = "Defend"
	def_btn.pressed.connect(func():
		command_panel.visible = false
		BattleManager.execute_defend()
	)
	if UITheme: UITheme.style_button(def_btn)
	command_buttons.add_child(def_btn)

	# Flee
	var flee_btn := Button.new()
	flee_btn.text = "Flee"
	flee_btn.pressed.connect(func():
		command_panel.visible = false
		if not BattleManager.execute_flee():
			_log("[color=gray]Can't escape![/color]")
	)
	if UITheme: UITheme.style_button(flee_btn)
	command_buttons.add_child(flee_btn)

	# Grab focus on first button for keyboard navigation
	await get_tree().process_frame
	atk_btn.grab_focus()

func _refresh_party() -> void:
	for child in party_container.get_children():
		child.queue_free()
	if UITheme:
		party_container.add_child(UITheme.styled_header("Party"))
	for c in BattleManager.party_combatants:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var name_lbl := Label.new()
		var status: String = "" if c["hp"] > 0 else " [KO]"
		name_lbl.text = c["name"] + status
		name_lbl.custom_minimum_size = Vector2(80, 0)
		if UITheme:
			name_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SIZE_SMALL)
			name_lbl.add_theme_color_override("font_color", UITheme.ACCENT if c["hp"] > 0 else UITheme.DANGER)
		row.add_child(name_lbl)
		if UITheme and c["hp"] > 0:
			row.add_child(UITheme.hp_bar(c["hp"], c["max_hp"]))
			row.add_child(UITheme.mp_bar(c["mp"], c["max_mp"]))
			# ATB gauge
			var atb_bar := ProgressBar.new()
			atb_bar.min_value = 0
			atb_bar.max_value = 100
			atb_bar.value = c.get("atb", 0)
			atb_bar.custom_minimum_size = Vector2(60, 10)
			atb_bar.show_percentage = false
			var fg := StyleBoxFlat.new()
			fg.bg_color = Color(0.9, 0.8, 0.2)
			fg.corner_radius_top_left = 2
			fg.corner_radius_top_right = 2
			fg.corner_radius_bottom_left = 2
			fg.corner_radius_bottom_right = 2
			atb_bar.add_theme_stylebox_override("fill", fg)
			row.add_child(atb_bar)
		party_container.add_child(row)

func _refresh_enemies() -> void:
	for child in enemy_container.get_children():
		child.queue_free()
	if UITheme:
		enemy_container.add_child(UITheme.styled_header("Enemies"))
	for c in BattleManager.enemy_combatants:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var name_lbl := Label.new()
		var status: String = "" if c["hp"] > 0 else " [DEAD]"
		name_lbl.text = c["name"] + status
		name_lbl.custom_minimum_size = Vector2(100, 0)
		if UITheme:
			name_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SIZE_SMALL)
			name_lbl.add_theme_color_override("font_color", UITheme.DANGER if c["hp"] > 0 else Color(0.4, 0.4, 0.4))
		row.add_child(name_lbl)
		if UITheme and c["hp"] > 0:
			row.add_child(UITheme.hp_bar(c["hp"], c["max_hp"]))
		enemy_container.add_child(row)

func _log(text: String) -> void:
	battle_log.append_text(text + "\n")

func _process(_delta: float) -> void:
	if not visible: return
	# Live-update ATB bars
	_refresh_party()

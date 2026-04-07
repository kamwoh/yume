extends Control

@onready var location_label: Label = $LocationLabel
@onready var gil_label: Label = $GilLabel
@onready var party_status: VBoxContainer = $PartyStatus
@onready var objective_label: Label = $ObjectiveLabel

var _update_timer: float = 0.0

func _ready() -> void:
	if UITheme:
		location_label.add_theme_color_override("font_color", UITheme.ACCENT)
		location_label.add_theme_font_size_override("font_size", UITheme.FONT_SIZE_HEADER)
		gil_label.add_theme_color_override("font_color", UITheme.TEXT_COLOR)
		gil_label.add_theme_font_size_override("font_size", UITheme.FONT_SIZE_SMALL)
		objective_label.add_theme_color_override("font_color", UITheme.ACCENT)
		objective_label.add_theme_font_size_override("font_size", 15)
		objective_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	# Connect to quest objective changes
	QuestManager.objective_changed.connect(_on_objective_changed)
	# Show initial objective after a short delay (autoloads may still be initializing)
	await get_tree().create_timer(0.5).timeout
	objective_label.text = QuestManager.get_current_objective()

func _on_objective_changed(text: String) -> void:
	objective_label.text = text

func _process(delta: float) -> void:
	if GameManager:
		gil_label.text = str(GameManager.gil) + " Gil"

	# Keep objective fresh — check every frame
	if QuestManager:
		var obj: String = QuestManager.get_current_objective()
		if obj == "" and QuestManager.active_quests.size() == 0 and QuestManager.completed_quests.size() == 0:
			obj = "..."  # Quest not loaded yet, don't show "Explore freely"
		elif obj == "":
			obj = "Explore freely"
		if objective_label.text != obj:
			objective_label.text = obj

	# Throttle party status updates (not every frame)
	_update_timer += delta
	if _update_timer > 0.5:
		_update_timer = 0.0
		_update_party_status()

func update_location(loc_name: String) -> void:
	location_label.text = loc_name

func _update_party_status() -> void:
	for child in party_status.get_children():
		child.queue_free()

	if not PartyManager:
		return

	for member in PartyManager.party:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		# Name + level
		var name_lbl := Label.new()
		name_lbl.text = "%s Lv.%d" % [member["name"], member["level"]]
		name_lbl.custom_minimum_size = Vector2(100, 0)
		if UITheme:
			name_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SIZE_SMALL)
			name_lbl.add_theme_color_override("font_color", UITheme.TEXT_COLOR)
		row.add_child(name_lbl)

		# HP bar
		if UITheme:
			var hp = UITheme.hp_bar(member["hp"], member["max_hp"])
			row.add_child(hp)

			# MP bar
			var mp = UITheme.mp_bar(member["mp"], member["max_mp"])
			row.add_child(mp)
		else:
			var hp_lbl := Label.new()
			hp_lbl.text = "HP:%d/%d" % [member["hp"], member["max_hp"]]
			hp_lbl.add_theme_font_size_override("font_size", 12)
			row.add_child(hp_lbl)

		party_status.add_child(row)

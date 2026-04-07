extends PanelContainer

@onready var speaker_label: Label = $VBox/SpeakerName
@onready var dialogue_text: RichTextLabel = $VBox/DialogueText
@onready var choice_container: VBoxContainer = $VBox/ChoiceContainer

var is_typing: bool = false
var full_text: String = ""
var type_speed: float = 0.03

func _ready() -> void:
	DialogueManager.dialogue_started.connect(_on_dialogue_started)
	DialogueManager.dialogue_line.connect(_on_dialogue_line)
	DialogueManager.dialogue_ended.connect(_on_dialogue_ended)
	visible = false

	# Apply theme styling
	if UITheme:
		UITheme.style_panel(self)
		speaker_label.add_theme_color_override("font_color", UITheme.ACCENT)
		speaker_label.add_theme_font_size_override("font_size", UITheme.FONT_SIZE_HEADER)
		dialogue_text.add_theme_color_override("default_color", UITheme.TEXT_COLOR)
		dialogue_text.add_theme_font_size_override("normal_font_size", UITheme.FONT_SIZE_BODY)

func _on_dialogue_started() -> void:
	visible = true

func _on_dialogue_line(speaker: String, text: String) -> void:
	speaker_label.text = speaker
	full_text = text
	_start_typewriter(text)

func _on_dialogue_ended() -> void:
	visible = false
	is_typing = false

func _start_typewriter(text: String) -> void:
	is_typing = true
	dialogue_text.text = ""
	for i in range(text.length()):
		if not is_typing:
			break
		dialogue_text.text = text.substr(0, i + 1)
		await get_tree().create_timer(type_speed).timeout
	dialogue_text.text = text
	is_typing = false

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("interact"):
		if is_typing:
			is_typing = false
			dialogue_text.text = full_text
		else:
			DialogueManager.advance()
		get_viewport().set_input_as_handled()

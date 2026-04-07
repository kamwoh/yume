extends CanvasLayer

var is_open: bool = false
var shop_items: Array = []

var main_panel: PanelContainer
var items_container: VBoxContainer
var gil_label: Label
var info_label: Label

func _ready() -> void:
	layer = 15
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.7)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	main_panel = PanelContainer.new()
	main_panel.set_anchors_preset(Control.PRESET_CENTER)
	main_panel.custom_minimum_size = Vector2(500, 400)
	if UITheme: UITheme.style_panel(main_panel)
	add_child(main_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	main_panel.add_child(vbox)

	# Title
	if UITheme:
		vbox.add_child(UITheme.styled_title("Shop"))
	else:
		var title := Label.new()
		title.text = "= SHOP ="
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(title)

	# Gil display
	gil_label = Label.new()
	gil_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if UITheme:
		gil_label.add_theme_font_size_override("font_size", UITheme.FONT_SIZE_BODY)
		gil_label.add_theme_color_override("font_color", UITheme.TEXT_COLOR)
	vbox.add_child(gil_label)

	# Scroll container for items
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 280)
	vbox.add_child(scroll)

	items_container = VBoxContainer.new()
	items_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	items_container.add_theme_constant_override("separation", 4)
	scroll.add_child(items_container)

	# Info label (selected item description)
	info_label = Label.new()
	info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_label.custom_minimum_size = Vector2(0, 40)
	if UITheme:
		info_label.add_theme_font_size_override("font_size", UITheme.FONT_SIZE_SMALL)
		info_label.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	vbox.add_child(info_label)

	# Close button
	var close_btn := Button.new()
	close_btn.text = "Close Shop"
	close_btn.pressed.connect(close_shop)
	if UITheme: UITheme.style_button(close_btn)
	vbox.add_child(close_btn)

func open_shop() -> void:
	# Load shop data from current location
	var loc_data: Dictionary = LocationManager.current_location_data
	shop_items = loc_data.get("shop", [])
	if shop_items.is_empty():
		DialogueManager.show_simple_message("Shopkeeper", "Sorry, nothing for sale here.")
		return

	is_open = true
	visible = true
	get_tree().paused = true
	_refresh()

func close_shop() -> void:
	is_open = false
	visible = false
	get_tree().paused = false

func _unhandled_input(event: InputEvent) -> void:
	if is_open and event.is_action_pressed("menu"):
		close_shop()
		get_viewport().set_input_as_handled()

func _refresh() -> void:
	gil_label.text = "Gil: " + str(GameManager.gil)

	for child in items_container.get_children():
		child.queue_free()

	for shop_entry in shop_items:
		var item_id: String = shop_entry.get("item_id", "")
		var price: int = shop_entry.get("price", 0)
		var item_data: Dictionary = InventoryManager.get_item_data(item_id)
		var item_name: String = item_data.get("name", item_id)
		var item_desc: String = item_data.get("description", "")
		var item_type: String = item_data.get("item_type", "")
		var owned: int = InventoryManager.items.filter(func(s): return s["id"] == item_id).size()
		var own_qty: int = 0
		for slot in InventoryManager.items:
			if slot["id"] == item_id:
				own_qty = slot["qty"]

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)

		# Item name + type
		var name_lbl := Label.new()
		name_lbl.text = item_name
		name_lbl.custom_minimum_size = Vector2(180, 0)
		if UITheme:
			name_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SIZE_BODY)
			name_lbl.add_theme_color_override("font_color", UITheme.TEXT_COLOR)
		row.add_child(name_lbl)

		# Type badge
		var type_lbl := Label.new()
		type_lbl.text = "[" + item_type + "]"
		type_lbl.custom_minimum_size = Vector2(80, 0)
		if UITheme:
			type_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SIZE_SMALL)
			type_lbl.add_theme_color_override("font_color", UITheme.TEXT_DIM)
		row.add_child(type_lbl)

		# Price
		var price_lbl := Label.new()
		price_lbl.text = str(price) + "g"
		price_lbl.custom_minimum_size = Vector2(60, 0)
		price_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		if UITheme:
			price_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SIZE_BODY)
			price_lbl.add_theme_color_override("font_color", UITheme.ACCENT)
		row.add_child(price_lbl)

		# Own count
		var own_lbl := Label.new()
		own_lbl.text = "Own: " + str(own_qty)
		own_lbl.custom_minimum_size = Vector2(50, 0)
		if UITheme:
			own_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SIZE_SMALL)
			own_lbl.add_theme_color_override("font_color", UITheme.TEXT_DIM)
		row.add_child(own_lbl)

		# Buy button
		var buy_btn := Button.new()
		buy_btn.text = "Buy"
		buy_btn.disabled = GameManager.gil < price
		var captured_id: String = item_id
		var captured_price: int = price
		var captured_name: String = item_name
		buy_btn.pressed.connect(func():
			if GameManager.spend_gil(captured_price):
				InventoryManager.add_item(captured_id)
				_refresh()
		)
		if UITheme: UITheme.style_button(buy_btn)
		row.add_child(buy_btn)

		# Hover → show description
		row.mouse_entered.connect(func():
			info_label.text = item_desc
		)

		items_container.add_child(row)

extends Node

signal battle_started
signal battle_ended(victory: bool)
signal combatant_ready(combatant: Dictionary)
signal combatant_acted(combatant: Dictionary, action: String, target: Dictionary, damage: int)
signal combatant_defeated(combatant: Dictionary)

enum BattleState { NONE, STARTING, ACTIVE, PLAYER_TURN, VICTORY, DEFEAT }

var state: int = BattleState.NONE
var in_battle: bool = false
var party_combatants: Array = []
var enemy_combatants: Array = []
var all_combatants: Array = []
var current_actor: Dictionary = {}
var return_location: String = ""

var enemy_db: Dictionary = {}

const ATB_FILL_RATE := 100.0
const VARIANCE := 0.15

func _ready() -> void:
	var file := FileAccess.open("res://data/enemies.json", FileAccess.READ)
	if file:
		var data = JSON.parse_string(file.get_as_text())
		if data is Array:
			for e in data:
				enemy_db[e["id"]] = e

func _process(delta: float) -> void:
	if state != BattleState.ACTIVE:
		return
	for c in all_combatants:
		if c.get("hp", 0) <= 0 or c.get("is_ready", false):
			continue
		var spd: float = c.get("speed", 5)
		c["atb"] = c.get("atb", 0.0) + (spd * ATB_FILL_RATE * delta / 100.0)
		if c["atb"] >= 100.0:
			c["atb"] = 100.0
			c["is_ready"] = true
			_on_combatant_ready(c)

func start_battle(p_enemy_ids: Array, p_return_loc: String) -> void:
	return_location = p_return_loc
	in_battle = true
	state = BattleState.STARTING

	party_combatants.clear()
	enemy_combatants.clear()
	all_combatants.clear()

	for member in PartyManager.party:
		var c: Dictionary = {
			"id": member["id"], "name": member["name"], "is_player": true,
			"hp": member["hp"], "max_hp": member["max_hp"],
			"mp": member["mp"], "max_mp": member["max_mp"],
			"strength": member["strength"], "magic": member["magic"],
			"defense": member["defense"], "spirit": member["spirit"],
			"speed": member["speed"],
			"atb": randf_range(0, 30), "is_ready": false, "is_defending": false,
		}
		party_combatants.append(c)
		all_combatants.append(c)

	for eid in p_enemy_ids:
		if enemy_db.has(eid):
			var edata: Dictionary = enemy_db[eid]
			var stats: Dictionary = edata.get("stats", {})
			var c: Dictionary = {
				"id": edata["id"], "name": edata.get("name", eid), "is_player": false,
				"hp": stats.get("hp", 50), "max_hp": stats.get("hp", 50),
				"mp": stats.get("mp", 0), "max_mp": stats.get("mp", 0),
				"strength": stats.get("strength", 8), "magic": stats.get("magic", 5),
				"defense": stats.get("defense", 5), "spirit": stats.get("spirit", 4),
				"speed": stats.get("speed", 6),
				"xp_reward": edata.get("xp_reward", 10),
				"gil_reward": edata.get("gil_reward", 15),
				"element_weak": edata.get("element_weak", "none"),
				"is_boss": edata.get("is_boss", false),
				"atb": randf_range(0, 20), "is_ready": false, "is_defending": false,
			}
			enemy_combatants.append(c)
			all_combatants.append(c)

	battle_started.emit()
	state = BattleState.ACTIVE

func _on_combatant_ready(combatant: Dictionary) -> void:
	# Skip dead combatants
	if combatant.get("hp", 0) <= 0:
		combatant["atb"] = 0.0
		combatant["is_ready"] = false
		return
	if combatant["is_player"]:
		state = BattleState.PLAYER_TURN
		current_actor = combatant
		combatant_ready.emit(combatant)
	else:
		_enemy_act(combatant)

func execute_attack(target: Dictionary) -> void:
	if current_actor.is_empty(): return
	var damage: int = _calc_physical(current_actor["strength"], target["defense"])
	if target.get("is_defending", false): damage /= 2
	_apply_damage(target, damage)
	combatant_acted.emit(current_actor, "Attack", target, damage)
	_end_turn(current_actor)

func execute_magic(ability_name: String, power: int, mp_cost: int, element: String, target_type: String) -> void:
	if current_actor.is_empty(): return
	if current_actor["mp"] < mp_cost: return
	current_actor["mp"] -= mp_cost

	if target_type == "all_enemies":
		for enemy in enemy_combatants:
			if enemy["hp"] > 0:
				var dmg: int = _calc_magical(current_actor["magic"], power, enemy["spirit"])
				if enemy.get("element_weak", "none") == element: dmg *= 2
				_apply_damage(enemy, dmg)
				combatant_acted.emit(current_actor, ability_name, enemy, dmg)
	elif target_type.begins_with("single_ally") or target_type.begins_with("all_all"):
		for ally in party_combatants:
			if ally["hp"] > 0:
				var heal_amt: int = int(current_actor["magic"] * power / 10.0)
				ally["hp"] = min(ally["hp"] + heal_amt, ally["max_hp"])
				combatant_acted.emit(current_actor, ability_name, ally, -heal_amt)
	else:
		var target: Dictionary = _first_alive_enemy()
		if not target.is_empty():
			var dmg: int = _calc_magical(current_actor["magic"], power, target["spirit"])
			if target.get("element_weak", "none") == element: dmg *= 2
			_apply_damage(target, dmg)
			combatant_acted.emit(current_actor, ability_name, target, dmg)
	_end_turn(current_actor)

func execute_item(item_id: String) -> void:
	if current_actor.is_empty(): return
	var item_data: Dictionary = InventoryManager.get_item_data(item_id)
	if item_data.is_empty(): return
	var heal_amt: int = item_data.get("heal_amount", 0)
	if heal_amt > 0:
		current_actor["hp"] = min(current_actor["hp"] + heal_amt, current_actor["max_hp"])
		combatant_acted.emit(current_actor, "Item: " + item_data.get("name", item_id), current_actor, -heal_amt)
	InventoryManager.remove_item(item_id)
	_end_turn(current_actor)

func execute_defend() -> void:
	if current_actor.is_empty(): return
	current_actor["is_defending"] = true
	combatant_acted.emit(current_actor, "Defend", current_actor, 0)
	_end_turn(current_actor)

func execute_flee() -> bool:
	for e in enemy_combatants:
		if e.get("is_boss", false): return false
	if randf() > 0.5:
		_end_battle(false, true)
		return true
	return false

func _enemy_act(enemy: Dictionary) -> void:
	var alive: Array = []
	for p in party_combatants:
		if p["hp"] > 0: alive.append(p)
	if alive.is_empty(): return

	# Boss AI: use abilities 40% of the time
	var abilities: Array = _get_enemy_abilities(enemy["id"])
	if enemy.get("is_boss", false) and abilities.size() > 0 and randf() < 0.4:
		var ability: Dictionary = abilities[randi() % abilities.size()]
		var power: int = ability.get("power", 20)
		var element: String = ability.get("element", "none")
		var target_type: String = ability.get("target", "single_enemy")
		var ability_name: String = ability.get("name", "Special")

		if target_type == "all_enemies":
			# Hits all party members
			for p in alive:
				var dmg: int = _calc_magical(enemy["magic"], power, p["spirit"])
				if p.get("is_defending", false): dmg /= 2
				_apply_damage(p, dmg)
				combatant_acted.emit(enemy, ability_name, p, dmg)
		else:
			var target: Dictionary = alive[randi() % alive.size()]
			var dmg: int = _calc_magical(enemy["magic"], power, target["spirit"])
			if target.get("is_defending", false): dmg /= 2
			_apply_damage(target, dmg)
			combatant_acted.emit(enemy, ability_name, target, dmg)
	else:
		# Normal attack
		var target: Dictionary = alive[randi() % alive.size()]
		var damage: int = _calc_physical(enemy["strength"], target["defense"])
		if target.get("is_defending", false): damage /= 2
		_apply_damage(target, damage)
		combatant_acted.emit(enemy, "Attack", target, damage)

	_end_turn(enemy)

func _get_enemy_abilities(enemy_id: String) -> Array:
	if enemy_db.has(enemy_id):
		return enemy_db[enemy_id].get("abilities", [])
	return []

func _end_turn(combatant: Dictionary) -> void:
	combatant["atb"] = 0.0
	combatant["is_ready"] = false
	if combatant["is_player"]:
		combatant["is_defending"] = false
	current_actor = {}
	state = BattleState.ACTIVE
	_check_battle_end()

func _apply_damage(target: Dictionary, damage: int) -> void:
	target["hp"] = max(target["hp"] - damage, 0)
	if target["hp"] <= 0:
		combatant_defeated.emit(target)

func _check_battle_end() -> void:
	var enemies_alive: bool = false
	for e in enemy_combatants:
		if e["hp"] > 0: enemies_alive = true; break
	var party_alive: bool = false
	for p in party_combatants:
		if p["hp"] > 0: party_alive = true; break

	if not enemies_alive:
		state = BattleState.VICTORY
		_end_battle(true, false)
	elif not party_alive:
		state = BattleState.DEFEAT
		_end_battle(false, false)

func _end_battle(victory: bool, fled: bool) -> void:
	if victory:
		var total_xp: int = 0
		var total_gil: int = 0
		for e in enemy_combatants:
			total_xp += e.get("xp_reward", 0)
			total_gil += e.get("gil_reward", 0)
		PartyManager.gain_xp(total_xp)
		GameManager.add_gil(total_gil)
	# Sync HP/MP back
	for c in party_combatants:
		for m in PartyManager.party:
			if m["id"] == c["id"]:
				m["hp"] = c["hp"]
				m["mp"] = c["mp"]

	# Notify story manager of boss defeats
	if victory:
		for e in enemy_combatants:
			if e.get("is_boss", false):
				var eid: String = e.get("enemy_id", e.get("id", ""))
				if has_node("/root/StoryManager"):
					StoryManager.on_boss_defeated(eid)
				QuestManager.on_trigger("defeat", eid)

	in_battle = false
	state = BattleState.NONE
	all_combatants.clear()
	party_combatants.clear()
	enemy_combatants.clear()
	current_actor = {}
	battle_ended.emit(victory)

func _calc_physical(atk: int, def: int) -> int:
	var base: int = max(atk * 2 - def, 1)
	return max(int(base * randf_range(0.85, 1.15)), 1)

func _calc_magical(mag: int, power: int, spr: int) -> int:
	var base: int = max((mag + power) * 2 - spr, 1)
	return max(int(base * randf_range(0.9, 1.1)), 1)

func _first_alive_enemy() -> Dictionary:
	for e in enemy_combatants:
		if e["hp"] > 0: return e
	return {}

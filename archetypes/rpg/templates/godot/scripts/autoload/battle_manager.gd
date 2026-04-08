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

var ATB_FILL_RATE: float = 100.0
var VARIANCE: float = 0.15

func _ready() -> void:
	# Load battle config from meta.json
	var meta_file := FileAccess.open("res://data/meta.json", FileAccess.READ)
	if meta_file:
		var meta = JSON.parse_string(meta_file.get_as_text())
		if meta is Dictionary:
			var battle: Dictionary = meta.get("battle", {})
			if battle is Dictionary:
				ATB_FILL_RATE = battle.get("atb_fill_rate", ATB_FILL_RATE)
				VARIANCE = battle.get("variance", VARIANCE)

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

## Generic ability execution — driven by ability data, NOT hardcoded names.
## Ability JSON: {name, type, power, mp_cost, element, target, stat, multiplier, duration, status}
## Types: damage, heal, steal, buff, debuff, taunt, status, drain
func execute_ability(ability: Dictionary) -> void:
	if current_actor.is_empty(): return
	var mp_cost: int = ability.get("mp_cost", 0)
	if current_actor["mp"] < mp_cost: return
	current_actor["mp"] -= mp_cost

	var ability_name: String = ability.get("name", "Attack")
	var ability_type: String = ability.get("type", "damage")
	var power: int = ability.get("power", 0)
	var element: String = ability.get("element", "none")
	var target_type: String = ability.get("target", "single_enemy")

	match ability_type:
		"steal":
			_do_steal(ability_name)
		"heal":
			_do_heal(ability_name, power, target_type)
		"buff":
			_do_buff(ability_name, ability)
		"debuff":
			_do_debuff(ability_name, ability)
		"taunt":
			_do_taunt(ability_name, ability)
		"drain":
			_do_drain(ability_name, power, element)
		"status":
			_do_status(ability_name, ability)
		_:  # "damage" or unknown — default to damage
			_do_damage(ability_name, power, element, target_type)

	_end_turn(current_actor)


func _do_damage(ability_name: String, power: int, element: String, target_type: String) -> void:
	if target_type == "all_enemies":
		for enemy in enemy_combatants:
			if enemy["hp"] > 0:
				var dmg: int = _calc_magical(current_actor["magic"], power, enemy["spirit"])
				if enemy.get("element_weak", "none") == element and element != "none":
					dmg *= 2
				_apply_damage(enemy, dmg)
				combatant_acted.emit(current_actor, ability_name, enemy, dmg)
	else:
		var target: Dictionary = _first_alive_enemy()
		if not target.is_empty():
			var dmg: int = _calc_magical(current_actor["magic"], power, target["spirit"])
			if target.get("element_weak", "none") == element and element != "none":
				dmg *= 2
			_apply_damage(target, dmg)
			combatant_acted.emit(current_actor, ability_name, target, dmg)


func _do_heal(ability_name: String, power: int, target_type: String) -> void:
	var targets: Array = []
	if target_type == "all_allies" or target_type == "all_all":
		targets = party_combatants
	elif target_type == "self":
		targets = [current_actor]
	else:
		# Single ally — heal lowest HP party member
		var lowest = {}
		for ally in party_combatants:
			if ally["hp"] > 0:
				if lowest.is_empty() or ally["hp"] < lowest["hp"]:
					lowest = ally
		if not lowest.is_empty():
			targets = [lowest]

	for ally in targets:
		if ally["hp"] > 0:
			var heal_amt: int = max(1, int(current_actor["magic"] * power / 10.0))
			ally["hp"] = min(ally["hp"] + heal_amt, ally["max_hp"])
			combatant_acted.emit(current_actor, ability_name, ally, -heal_amt)


func _do_steal(ability_name: String) -> void:
	var target: Dictionary = _first_alive_enemy()
	if target.is_empty(): return

	var enemy_id: String = target.get("id", "")
	var steal_table: Array = []
	if enemy_db.has(enemy_id):
		steal_table = enemy_db[enemy_id].get("steal_table", [])

	var stolen: bool = false
	for item in steal_table:
		var chance: float = item.get("chance", 0.3)
		if randf() < chance:
			var item_id: String = item.get("item_id", "")
			if item_id != "":
				InventoryManager.add_item(item_id)
				combatant_acted.emit(current_actor, "Stole " + item_id + "!", target, 0)
				stolen = true
				break
	if not stolen:
		combatant_acted.emit(current_actor, "Couldn't steal anything!", target, 0)


func _do_buff(ability_name: String, ability: Dictionary) -> void:
	var stat: String = ability.get("stat", "strength")
	var multiplier: float = ability.get("multiplier", 1.5)
	var target_type: String = ability.get("target", "self")

	var targets: Array = []
	if target_type == "all_allies":
		targets = party_combatants
	elif target_type == "self":
		targets = [current_actor]
	else:
		targets = [current_actor]

	for t in targets:
		if t["hp"] > 0:
			var original: int = t.get(stat, 10)
			t[stat] = int(original * multiplier)
			combatant_acted.emit(current_actor, ability_name + " (" + stat + " UP!)", t, 0)


func _do_debuff(ability_name: String, ability: Dictionary) -> void:
	var stat: String = ability.get("stat", "defense")
	var multiplier: float = ability.get("multiplier", 0.5)
	var target: Dictionary = _first_alive_enemy()
	if not target.is_empty():
		var original: int = target.get(stat, 10)
		target[stat] = int(original * multiplier)
		combatant_acted.emit(current_actor, ability_name + " (" + stat + " DOWN!)", target, 0)


func _do_taunt(ability_name: String, ability: Dictionary) -> void:
	current_actor["is_taunting"] = true
	combatant_acted.emit(current_actor, ability_name + " (Drawing attacks!)", current_actor, 0)


func _do_drain(ability_name: String, power: int, element: String) -> void:
	var target: Dictionary = _first_alive_enemy()
	if not target.is_empty():
		var dmg: int = _calc_magical(current_actor["magic"], power, target["spirit"])
		if target.get("element_weak", "none") == element and element != "none":
			dmg *= 2
		_apply_damage(target, dmg)
		# Heal caster for portion of damage
		var heal: int = dmg / 2
		current_actor["hp"] = min(current_actor["hp"] + heal, current_actor["max_hp"])
		combatant_acted.emit(current_actor, ability_name, target, dmg)


func _do_status(ability_name: String, ability: Dictionary) -> void:
	var status_effect: String = ability.get("status", "")
	var target: Dictionary = _first_alive_enemy()
	if not target.is_empty() and status_effect != "":
		target["status_" + status_effect] = true
		combatant_acted.emit(current_actor, ability_name + " (" + status_effect + "!)", target, 0)


## Legacy wrapper — called by battle_ui.gd
func execute_magic(ability_name: String, power: int, mp_cost: int, element: String, target_type: String) -> void:
	# Convert old-style call to new ability system
	execute_ability({
		"name": ability_name, "type": "damage", "power": power,
		"mp_cost": mp_cost, "element": element, "target": target_type
	})

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

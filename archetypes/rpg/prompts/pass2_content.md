Generate gameplay content from the story structure. You receive the structure JSON (characters, locations, progression) from Pass 1.

Output keys: quests, items, enemies, dialogues, combat_encounters.

quests[]: {id, name, quest_type (main|side), description, steps: [{description, trigger (talk_to:id|defeat:id|reach:id|collect:id), optional}], rewards: [item_id], xp_reward, gil_reward, prerequisite: quest_id?}

items[]: {id, name, item_type (consumable|weapon|armor|accessory|key_item), description, stats: {strength?, defense?, etc}, price, element (none|fire|ice|thunder|water|wind|earth|holy|dark), usable_in_battle, heal_amount}

enemies[]: {id, name, description, stats: {hp,mp,strength,magic,defense,spirit,speed,level}, abilities: [{name,description,mp_cost,power,element,target,learn_level}], element_weak, element_resist, drop_table: [{item_id, chance}], xp_reward, gil_reward, sprite_prompt, is_boss}

dialogues[]: {id, location_id, lines: [{speaker,text,expression}], branches: [{prompt,next_node,condition?}], trigger_condition (interact|auto|quest:id), sets_flag?}

combat_encounters[]: {id, location_id, enemy_ids: [], trigger (random|story|boss), encounter_rate, is_boss_fight}

Rules:
- 1+ main quest per act, 1-2 side quests per act
- Boss characters from structure MUST also appear as enemies with is_boss=true
- Every field/dungeon location needs random encounters
- Quest reward item_ids and drop_table item_ids must exist in items list
- Enemy difficulty scales with progression (early=weak, late=strong)
- Economy: potion=50g, early weapons=100-300g, mid=500-1500g, late=2000-5000g

Return ONLY valid JSON.
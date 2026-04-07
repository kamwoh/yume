Review and fix numerical balance in this GDD. Return ONLY corrections as JSON — omit categories that are already balanced.

Output keys (all optional): character_stats, character_abilities, enemy_stats, item_stats, level_curve, starting_items.

character_stats: {character_id: {hp,mp,strength,magic,defense,spirit,speed,level}}
character_abilities: {character_id: [{name,description,mp_cost,power,element,target,learn_level}]}
enemy_stats: {enemy_id: {hp,mp,strength,magic,defense,spirit,speed,level}}
item_stats: {item_id: {stats,price,heal_amount}}
level_curve: [{act,expected_level}]
starting_items: [item_id, ...]

Balance targets:
- Party HP: 80-150, MP: 20-80 at level 1. Tanks=high HP/DEF, mages=high MP/MAG.
- Trash mobs: 60-80% of player stats. Bosses: 150-200% HP, 120-150% others.
- ~3-5 levels per act. Early abilities: 3-8 MP, 10-20 power. Late: 30-60 MP, 60-120 power.
- Each party member needs 2+ abilities.
- Start with 3-5 potions minimum.

Return ONLY valid JSON.
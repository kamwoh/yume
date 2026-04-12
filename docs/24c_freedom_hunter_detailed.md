# Freedom-Hunter — Detailed Godot Combat & AI Patterns

## Source: /mnt/c/Users/kamwoh/Documents/Projects/Personal/Freedom-Hunter/
## Engine: Godot 4.3, GDScript — DIRECTLY usable in Yume

## Project Structure
```
src/entities/     — Entity, Player, Monster (CharacterBody3D)
src/equipment/    — Weapon, Armor, Equipment base
src/items/        — Item, Consumable (Potion, Whetstone, Meat)
src/interact/     — Gathering, NPCs, chests, cannons
src/interface/    — HUD and UI
src/multiplayer/  — ENet networking
data/scenes/      — Godot scenes
```
~50 GDScript files, ~3,300 lines total.

## Combat System

### Entity Base (entity.gd extends CharacterBody3D)
- HP: current + recoverable (hp_regenerable tracks max recovery)
- Stamina: max 200, costs per action, regen varies by state
- AnimationTree with StateMachinePlayback
- States: idle, movement, attack, rest, death

### Stamina Costs
- Dodge: 10
- Jump: 15
- Run: 5 per frame
- Regen: idle=4, rest=12, walk=2

### Damage Model
```
actual_damage = input_damage - defense
hp -= actual_damage
hp_regenerable = hp + damage * regenerable_fraction
```
Element-based ailments: fire→burning (ticks), poison, paralysis, etc.

### Attack Flow
1. Input triggers attack
2. AnimationTree condition set: `parameters/conditions/attacking = true`
3. Animation plays → collision check via Area3D
4. On hit: damage() called on target

## Monster AI (monster.gd)

### State Machine
```gdscript
_physics_process(delta):
  if target_player != null: check_target()   # still visible?
  if target_player == null: find_new_target() # nearest visible
  if target_player != null: hunt_target()     # chase + attack
  else: scout()                               # random patrol
  move_entity(delta)
```

### Hunt Logic
```
distance > 10: run()
distance > 5: walk()
distance <= 5: attack()
```

### AI Features
- Line of sight: raycast with configurable FOV
- NavigationAgent3D for pathfinding
- Multiple player tracking (array)
- Target switching to nearest visible
- Exported tuning properties

## Equipment System

### Weapon (weapon.gd extends Area3D)
- Sharpness system: 7 tiers (purple→white→blue→green→yellow→orange→red)
- Each tier has max value, decreases on hit
- `blunt()`: damage tiers, `sharpen()`: restore
- Attached via BoneAttachment3D to skeleton

### Armor (armour.gd)
- 5 slots: head, torso, rightarm, leftarm, leg
- Each piece has strength value
- Total defense = sum of armor strengths

## Inventory (inventory.gd extends Panel)
- Max 30 slots
- Drag-and-drop with nested Slot class
- ItemStack displays quantity with color coding
- Signal: `modified` on any change

## Item System
- Item base: name, icon, quantity, rarity (0-99), clone()
- Consumable: max_quantity cap, effect(target) callback
- Potion: heals HP, triggers "drink" animation
- Whetstone: sharpens weapon
- Meat: increases max stamina

## Camera (camera.gd)
- Two-axis rotation: yaw (global Y) + pitch (local X)
- Smooth lerp: yaw delta*10, pitch delta*5
- Input: mouse, touch drag, gyroscope, gamepad
- Zoom in/out, pitch lock (CTRL), reset (middle click)

## Multiplayer
- ENetMultiplayerPeer
- RPC for stat changes: @rpc("any_peer", "call_local")
- Authority per entity: set_multiplayer_authority(id)
- Sync: HP/stamina via RPC, transforms commented out
- Connection flow: server starts → client connects → register_player RPC

## Patterns Directly Usable in Yume
1. AnimationTree state machine for combat states
2. NavigationAgent3D for pathfinding (replace our direct walk-to)
3. Stamina as resource with per-state regen rates
4. BoneAttachment3D for visual weapon equipping
5. RPC multiplayer pattern for multi-agent sync
6. Signal-driven architecture (HP/stamina/item changes → signals)
7. Damage model: actual = input - defense + element ailments

## Key Files
- src/entities/entity.gd — combat core
- src/entities/monster.gd — monster AI
- src/equipment/weapon.gd — sharpness system
- src/items/consumables/potion.gd — consumable pattern
- src/inventory.gd — drag-drop inventory
- src/multiplayer/networking.gd — RPC sync
- src/camera.gd — multi-input third-person

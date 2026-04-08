Extract characters, locations, and plot structure from the story as JSON.

Output keys: meta, characters, locations, progression.

meta: {title, game_type, art_style (detailed visual style for asset consistency), description, ui_theme, player, battle, collision}

ui_theme: derive ALL colors from art_style. Dark game = dark panels. Bright game = light panels.
  {panel_bg: [r,g,b,a], panel_border: [r,g,b,a], accent: [r,g,b,a], text_color: [r,g,b,a], text_dim: [r,g,b,a], hp_color: [r,g,b,a], mp_color: [r,g,b,a], danger: [r,g,b,a], font_size_title: int, font_size_body: int}

player: {move_speed (fast=250, normal=200, slow=150), interact_range: 40}

battle: {atb_fill_rate (fast=120, normal=100, slow=80), variance: 0.15}

collision: {prop: [w,h], npc: [w,h], exit: [w,h], treasure: [w,h]}

characters[]: {id (lowercase_underscore), name, role (party_member|npc|antagonist|boss), character_class, description (appearance+personality), backstory, portrait_prompt, sprite_prompts: {idle, walk, attack?, hurt?, dead?}}

locations[]: {id, name, location_type (town|dungeon|field|world_map|interior|special), description, background_prompt, connections: [location_id], npcs: [character_id]}

progression: {acts, story_beats: [{act, description, location_id, quest_id?}], starting_party: [character_id], starting_location, starting_items: []}

visual_config: {character_base, npc_types, prop_types, chest, exit_marker}
  Derive proportions from art_style. Chibi game = small body, big head. Realistic = tall body, normal head.
  Define npc_types for each archetype in the story (guard, merchant, scientist, alien, etc.)
  Define prop_types for each environment (trees for forest, consoles for space station, etc.)

Rules:
- EVERY visual/gameplay constant MUST be in meta.json or visual_config.json. The engine has NO game-specific defaults.
- Party members need role "party_member", "color" field [r,g,b], and all sprite_prompt fields
- Bosses/antagonists need role "boss"/"antagonist" and sprite_prompts
- NPCs need only idle+walk sprites
- Locations must form a connected graph
- starting_party/starting_location must reference valid IDs
- IDs: unique, lowercase, underscores only
- Art prompts must reference the meta.art_style for consistency

Return ONLY valid JSON.
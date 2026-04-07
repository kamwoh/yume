Extract characters, locations, and plot structure from the story as JSON.

Output keys: meta, characters, locations, progression.

meta: {title, game_type, art_style (detailed visual style for asset consistency), description}

characters[]: {id (lowercase_underscore), name, role (party_member|npc|antagonist|boss), character_class, description (appearance+personality), backstory, portrait_prompt, sprite_prompts: {idle, walk, attack?, hurt?, dead?}}

locations[]: {id, name, location_type (town|dungeon|field|world_map|interior|special), description, background_prompt, connections: [location_id], npcs: [character_id]}

progression: {acts, story_beats: [{act, description, location_id, quest_id?}], starting_party: [character_id], starting_location, starting_items: []}

Rules:
- Party members need role "party_member" and all sprite_prompt fields
- Bosses/antagonists need role "boss"/"antagonist" and sprite_prompts
- NPCs need only idle+walk sprites
- Locations must form a connected graph
- starting_party/starting_location must reference valid IDs
- IDs: unique, lowercase, underscores only
- Art prompts must reference the meta.art_style for consistency

Return ONLY valid JSON.
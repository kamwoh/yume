"""GDD validation helpers — referential integrity checks beyond Pydantic's type validation."""

from __future__ import annotations

from dataclasses import dataclass, field

from yume.schema.gdd import GDD


@dataclass
class ValidationResult:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return len(self.errors) == 0

    def summary(self) -> str:
        lines = []
        if self.errors:
            lines.append(f"{len(self.errors)} error(s):")
            lines.extend(f"  - {e}" for e in self.errors)
        if self.warnings:
            lines.append(f"{len(self.warnings)} warning(s):")
            lines.extend(f"  - {w}" for w in self.warnings)
        if not lines:
            lines.append("GDD is valid.")
        return "\n".join(lines)


def validate_gdd(gdd: GDD) -> ValidationResult:
    """Run referential integrity checks on a parsed GDD.

    Checks that all cross-references (IDs) actually point to existing entities.
    """
    result = ValidationResult()

    # Build ID sets
    char_ids = {c.id for c in gdd.characters}
    loc_ids = {loc.id for loc in gdd.locations}
    quest_ids = {q.id for q in gdd.quests}
    item_ids = {i.id for i in gdd.items}
    enemy_ids = {e.id for e in gdd.enemies}

    # Check location connections
    for loc in gdd.locations:
        for conn in loc.connections:
            if conn not in loc_ids:
                result.errors.append(f"Location '{loc.id}' connects to unknown location '{conn}'")
        for npc in loc.npcs:
            if npc not in char_ids:
                result.errors.append(f"Location '{loc.id}' references unknown character '{npc}'")
        for entry in loc.shop:
            if entry.item_id not in item_ids:
                result.errors.append(f"Location '{loc.id}' shop has unknown item '{entry.item_id}'")

    # Check quest references
    for quest in gdd.quests:
        if quest.prerequisite and quest.prerequisite not in quest_ids:
            result.errors.append(f"Quest '{quest.id}' has unknown prerequisite '{quest.prerequisite}'")
        for reward in quest.rewards:
            if reward not in item_ids:
                result.warnings.append(f"Quest '{quest.id}' rewards unknown item '{reward}'")

    # Check combat encounters
    for enc in gdd.combat_encounters:
        if enc.location_id not in loc_ids:
            result.errors.append(f"Encounter '{enc.id}' references unknown location '{enc.location_id}'")
        for eid in enc.enemy_ids:
            if eid not in enemy_ids:
                result.errors.append(f"Encounter '{enc.id}' references unknown enemy '{eid}'")

    # Check enemy drop tables
    for enemy in gdd.enemies:
        for drop in enemy.drop_table:
            if drop.item_id not in item_ids:
                result.warnings.append(f"Enemy '{enemy.id}' drops unknown item '{drop.item_id}'")

    # Check dialogue references
    for dlg in gdd.dialogues:
        if dlg.location_id not in loc_ids:
            result.errors.append(f"Dialogue '{dlg.id}' references unknown location '{dlg.location_id}'")

    # Check progression references
    prog = gdd.progression
    for cid in prog.starting_party:
        if cid not in char_ids:
            result.errors.append(f"Starting party references unknown character '{cid}'")
    if prog.starting_location not in loc_ids:
        result.errors.append(f"Starting location '{prog.starting_location}' not found")
    for iid in prog.starting_items:
        if iid not in item_ids:
            result.warnings.append(f"Starting items references unknown item '{iid}'")

    # Check party members have stats
    for char in gdd.characters:
        if char.role.value == "party_member" and char.stats is None:
            result.errors.append(f"Party member '{char.id}' is missing stats")

    return result

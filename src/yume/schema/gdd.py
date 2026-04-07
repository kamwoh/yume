"""Game Design Document schema — the contract between the story parser and the generator."""

from __future__ import annotations

from enum import Enum
from typing import Any

from pydantic import BaseModel, Field


# --- Enums ---


class GameType(str, Enum):
    RPG = "rpg"


class CharacterRole(str, Enum):
    PARTY_MEMBER = "party_member"
    NPC = "npc"
    ANTAGONIST = "antagonist"
    BOSS = "boss"


class LocationType(str, Enum):
    TOWN = "town"
    DUNGEON = "dungeon"
    FIELD = "field"
    WORLD_MAP = "world_map"
    INTERIOR = "interior"
    SPECIAL = "special"


class QuestType(str, Enum):
    MAIN = "main"
    SIDE = "side"


class ItemType(str, Enum):
    CONSUMABLE = "consumable"
    WEAPON = "weapon"
    ARMOR = "armor"
    ACCESSORY = "accessory"
    KEY_ITEM = "key_item"


class ElementType(str, Enum):
    FIRE = "fire"
    ICE = "ice"
    THUNDER = "thunder"
    WATER = "water"
    WIND = "wind"
    EARTH = "earth"
    HOLY = "holy"
    DARK = "dark"
    NONE = "none"


# --- Sub-models ---


class Stats(BaseModel):
    """Base stats for characters and enemies."""

    hp: int = Field(ge=1, description="Hit points")
    mp: int = Field(ge=0, description="Magic points")
    strength: int = Field(ge=1, description="Physical attack power")
    magic: int = Field(ge=1, description="Magical attack power")
    defense: int = Field(ge=1, description="Physical defense")
    spirit: int = Field(ge=1, description="Magical defense")
    speed: int = Field(ge=1, description="Determines ATB fill rate")
    level: int = Field(ge=1, default=1)


class Ability(BaseModel):
    """A skill or spell usable in combat."""

    name: str
    description: str
    mp_cost: int = Field(ge=0, default=0)
    power: int = Field(ge=0, default=0)
    element: ElementType = ElementType.NONE
    target: str = Field(default="single_enemy", description="single_enemy|all_enemies|single_ally|all_allies|self")
    learn_level: int = Field(ge=1, default=1, description="Level at which this ability is learned")


class SpritePrompts(BaseModel):
    """Image generation prompts for a character's sprite sheet."""

    idle: str = Field(description="Prompt for idle pose")
    walk: str = Field(description="Prompt for walk cycle")
    attack: str | None = Field(default=None, description="Prompt for attack animation")
    hurt: str | None = Field(default=None, description="Prompt for hurt/damage pose")
    dead: str | None = Field(default=None, description="Prompt for KO pose")


class DropTableEntry(BaseModel):
    """An item drop with probability."""

    item_id: str
    chance: float = Field(ge=0.0, le=1.0, description="Drop probability 0.0-1.0")


class DialogueLine(BaseModel):
    """A single line in a dialogue sequence."""

    speaker: str
    text: str
    expression: str = Field(default="neutral", description="Speaker's portrait expression")


class DialogueBranch(BaseModel):
    """A player choice within dialogue."""

    prompt: str = Field(description="The choice text shown to the player")
    next_node: str = Field(description="ID of the next dialogue node")
    condition: str | None = Field(default=None, description="Optional flag/condition to show this choice")


class QuestStep(BaseModel):
    """A single objective within a quest."""

    description: str
    trigger: str = Field(description="What triggers completion: talk_to:<npc_id>, defeat:<enemy_id>, reach:<location_id>, collect:<item_id>")
    optional: bool = False


class StoryBeat(BaseModel):
    """A key narrative moment tied to progression."""

    act: int = Field(ge=1)
    description: str
    location_id: str
    quest_id: str | None = None


class LevelCurvePoint(BaseModel):
    """Expected player level at a story beat."""

    act: int = Field(ge=1)
    expected_level: int = Field(ge=1)


class ShopInventoryEntry(BaseModel):
    """An item available in a shop."""

    item_id: str
    price: int = Field(ge=0)


# --- Top-level models ---


class GameMeta(BaseModel):
    """High-level game metadata."""

    title: str
    game_type: GameType = GameType.RPG
    art_style: str = Field(description="Visual style description for consistent asset generation")
    description: str = Field(default="", description="One-paragraph game summary")
    unity_version: str = Field(default="6000.0", description="Target Unity version")


class Character(BaseModel):
    """A character in the game — party member, NPC, or antagonist."""

    id: str = Field(description="Unique identifier, e.g. 'zidane'")
    name: str
    role: CharacterRole
    character_class: str = Field(default="", description="e.g. Thief, Black Mage, Knight")
    description: str = Field(description="Physical appearance and personality")
    backstory: str = Field(default="")
    stats: Stats | None = Field(default=None, description="Base stats (required for party members and bosses)")
    abilities: list[Ability] = Field(default_factory=list)
    portrait_prompt: str = Field(default="", description="Image gen prompt for dialogue portrait")
    sprite_prompts: SpritePrompts | None = None


class Location(BaseModel):
    """A visitable location/map in the game."""

    id: str
    name: str
    location_type: LocationType
    description: str = Field(description="Visual/atmospheric description")
    background_prompt: str = Field(default="", description="Image gen prompt for background art")
    connections: list[str] = Field(default_factory=list, description="IDs of connected locations")
    npcs: list[str] = Field(default_factory=list, description="Character IDs present here")
    events: list[str] = Field(default_factory=list, description="Event/quest IDs triggered here")
    shop: list[ShopInventoryEntry] = Field(default_factory=list, description="Items for sale if this location has a shop")


class Quest(BaseModel):
    """A quest — main story or side quest."""

    id: str
    name: str
    quest_type: QuestType
    description: str
    steps: list[QuestStep] = Field(min_length=1)
    rewards: list[str] = Field(default_factory=list, description="Item IDs given on completion")
    xp_reward: int = Field(ge=0, default=0)
    gil_reward: int = Field(ge=0, default=0)
    prerequisite: str | None = Field(default=None, description="Quest ID that must be completed first")


class Item(BaseModel):
    """An item — consumable, equipment, or key item."""

    id: str
    name: str
    item_type: ItemType
    description: str
    stats: dict[str, int] = Field(default_factory=dict, description="Stat modifiers, e.g. {'strength': 5, 'defense': 3}")
    price: int = Field(ge=0, default=0, description="Base buy price (sell = half)")
    element: ElementType = ElementType.NONE
    usable_in_battle: bool = False
    heal_amount: int = Field(ge=0, default=0, description="HP restored if consumable")


class Enemy(BaseModel):
    """An enemy encounter-able in battle."""

    id: str
    name: str
    description: str
    stats: Stats
    abilities: list[Ability] = Field(default_factory=list)
    element_weak: ElementType = ElementType.NONE
    element_resist: ElementType = ElementType.NONE
    drop_table: list[DropTableEntry] = Field(default_factory=list)
    xp_reward: int = Field(ge=0, default=0)
    gil_reward: int = Field(ge=0, default=0)
    sprite_prompt: str = Field(default="", description="Image gen prompt for battle sprite")
    is_boss: bool = False


class DialogueTree(BaseModel):
    """A dialogue sequence triggered by NPC interaction or event."""

    id: str
    location_id: str = Field(description="Where this dialogue can be triggered")
    lines: list[DialogueLine] = Field(min_length=1)
    branches: list[DialogueBranch] = Field(default_factory=list)
    trigger_condition: str = Field(default="interact", description="interact|auto|quest:<quest_id>")
    sets_flag: str | None = Field(default=None, description="Game flag set after this dialogue completes")


class CombatEncounter(BaseModel):
    """A combat encounter definition."""

    id: str
    location_id: str
    enemy_ids: list[str] = Field(min_length=1, description="Enemy IDs in this encounter")
    trigger: str = Field(default="random", description="random|story|boss")
    encounter_rate: float = Field(ge=0.0, le=1.0, default=0.15, description="Chance per step for random encounters")
    is_boss_fight: bool = False


class Progression(BaseModel):
    """Overall game progression and balance data."""

    acts: int = Field(ge=1, description="Number of story acts")
    story_beats: list[StoryBeat] = Field(default_factory=list)
    level_curve: list[LevelCurvePoint] = Field(default_factory=list)
    starting_party: list[str] = Field(description="Character IDs in the starting party")
    starting_location: str = Field(description="Location ID where the game begins")
    starting_items: list[str] = Field(default_factory=list, description="Item IDs the player starts with")


# --- Root GDD ---


class GDD(BaseModel):
    """The complete Game Design Document — output of the story parser, input to the generator."""

    meta: GameMeta
    characters: list[Character] = Field(min_length=1)
    locations: list[Location] = Field(min_length=1)
    quests: list[Quest] = Field(default_factory=list)
    items: list[Item] = Field(default_factory=list)
    enemies: list[Enemy] = Field(default_factory=list)
    dialogues: list[DialogueTree] = Field(default_factory=list)
    combat_encounters: list[CombatEncounter] = Field(default_factory=list)
    progression: Progression

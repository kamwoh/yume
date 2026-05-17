"""
lib_refs.py — builders for @-prefixed references (ADR 0027 lib system).

References:
    @lib.<bundle>.<member>   — resolve via data/lib/manifest.json
                               (e.g. @lib.input.universal.actions)
    @cues.<name>             — audio cue mapping in audio/cues.json
    @strings.<dotted.key>    — localizable text in ui/strings.json

Each helper returns the canonical string form. Pass them through any
JSON field that accepts at-refs (HUD label.text, audio play_sound,
input.json $include, etc.).
"""


def lib_ref(*segments: str) -> str:
    """Build a @lib reference: lib_ref("input", "universal") →
    "@lib.input.universal". Member names like ".actions" can be
    appended directly to the returned string.

    Empty segments are filtered out for ergonomics. Validators check
    that the result resolves through data/lib/manifest.json at sync
    time (tools/validate_lib_refs.py)."""
    parts = [s for s in segments if s]
    if not parts:
        raise ValueError("lib_ref: at least one segment required")
    return "@lib." + ".".join(parts)


def include_lib(*segments: str) -> dict:
    """Build a $include shell that the LibResolver picks up.

        include_lib("input", "universal", "actions")
        →
        {"$include": "@lib.input.universal.actions"}

    Typically used inline in an actions: array:

        "actions": [
            include_lib("input", "universal", "actions"),
            {"name": "restart", "key": "R", "edge": "press"},
        ]
    """
    return {"$include": lib_ref(*segments)}


def cue_ref(name: str) -> str:
    """Build a @cues reference: cue_ref("sale_clinch") →
    "@cues.sale_clinch". Maps to audio/cues.json at runtime."""
    if not name:
        raise ValueError("cue_ref: name required")
    return "@cues." + name


def string_ref(*segments: str) -> str:
    """Build a @strings reference. Dotted segments drill into the
    nested strings dict in ui/strings.json:

        string_ref("hud", "objective", "find_food")
        →
        "@strings.hud.objective.find_food"
    """
    parts = [s for s in segments if s]
    if not parts:
        raise ValueError("string_ref: at least one segment required")
    return "@strings." + ".".join(parts)

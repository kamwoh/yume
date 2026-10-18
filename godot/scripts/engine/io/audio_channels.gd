class_name AudioChannels
extends RefCounted
## ADR 0090 — the audio channels of the spec.
##
## Content sets the volume of a channel by name: `master`, `music` or
## `sfx`. Music plays on `music`, and sound cues play on `sfx`. Both feed
## `master`. This table maps each name to a Godot audio bus, which the
## interpreter makes at startup.
##
## validate_host_neutral.py and gen_api_manifest.py read CHANNELS from
## this file. A new channel needs an ADR.

const CHANNELS := {"master": "Master", "music": "Music", "sfx": "SFX"}


## Make the host bus of each channel. Godot always has "Master".
## Safe to call more than once.
static func ensure_buses() -> void:
	for channel in CHANNELS:
		var bus_name: String = CHANNELS[channel]
		if AudioServer.get_bus_index(bus_name) >= 0:
			continue
		AudioServer.add_bus()
		var idx := AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, CHANNELS["master"])


## The host bus of `channel`, or "" after audio.unknown_channel.
## `where` names the JSON field for the error message.
static func bus(channel: String, where: String) -> String:
	if CHANNELS.has(channel):
		return CHANNELS[channel]
	push_error(
		"%s: %s '%s' is not an audio channel. The channels are: %s (ADR 0090)."
		% [EngineError.AUDIO_UNKNOWN_CHANNEL, where, channel, ", ".join(CHANNELS.keys())]
	)
	return ""

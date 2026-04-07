extends Node

# Audio Manager — handles BGM per location + SFX for game events
# BGM files go in res://assets/audio/bgm/ (e.g., town.ogg, dungeon.ogg)
# SFX files go in res://assets/audio/sfx/ (e.g., hit.ogg, menu.ogg)

var bgm_player: AudioStreamPlayer
var sfx_player: AudioStreamPlayer
var current_bgm: String = ""
var bgm_volume: float = -5.0  # dB
var sfx_volume: float = 0.0   # dB

# Map location types to BGM track names
const BGM_MAP := {
	"town": "town",
	"dungeon": "dungeon",
	"field": "field",
	"special": "special",
	"world_map": "field",
	"interior": "town",
}

# Map music moods (from location JSON) to BGM tracks
const MOOD_MAP := {
	"noble_peaceful": "town",
	"ominous_dark": "dungeon",
	"frozen_ethereal": "dungeon",
	"pastoral_idyllic": "town",
	"industrial_grand": "town",
	"rain_melancholy": "dungeon",
	"serene_doomed": "special",
	"coastal_melancholic": "field",
	"jungle_mysterious": "field",
	"corrupted_foreboding": "dungeon",
	"alien_haunting": "special",
	"cosmic_final": "special",
}

func _ready() -> void:
	bgm_player = AudioStreamPlayer.new()
	bgm_player.name = "BGMPlayer"
	bgm_player.bus = "Master"
	bgm_player.volume_db = bgm_volume
	add_child(bgm_player)

	sfx_player = AudioStreamPlayer.new()
	sfx_player.name = "SFXPlayer"
	sfx_player.bus = "Master"
	sfx_player.volume_db = sfx_volume
	add_child(sfx_player)

func play_bgm_for_location(location_type: String, music_mood: String = "") -> void:
	# Determine which BGM track to play
	var track_name: String = ""
	if music_mood != "":
		track_name = MOOD_MAP.get(music_mood, "")
	if track_name == "":
		track_name = BGM_MAP.get(location_type, "town")

	if track_name == current_bgm:
		return  # Already playing

	var path: String = "res://assets/audio/bgm/" + track_name + ".ogg"
	if not ResourceLoader.exists(path):
		# Try .mp3
		path = "res://assets/audio/bgm/" + track_name + ".mp3"
	if not ResourceLoader.exists(path):
		# Try .wav
		path = "res://assets/audio/bgm/" + track_name + ".wav"
	if not ResourceLoader.exists(path):
		# No audio file found — silent mode
		bgm_player.stop()
		current_bgm = ""
		return

	var stream = load(path)
	if stream:
		current_bgm = track_name
		# Crossfade: fade out old, play new
		var tween := create_tween()
		tween.tween_property(bgm_player, "volume_db", -40.0, 0.5)
		await tween.finished
		bgm_player.stream = stream
		bgm_player.play()
		var tween2 := create_tween()
		tween2.tween_property(bgm_player, "volume_db", bgm_volume, 0.5)

func play_battle_bgm() -> void:
	var path: String = "res://assets/audio/bgm/battle.ogg"
	if not ResourceLoader.exists(path):
		path = "res://assets/audio/bgm/battle.mp3"
	if not ResourceLoader.exists(path):
		return
	var stream = load(path)
	if stream:
		bgm_player.stop()
		bgm_player.stream = stream
		bgm_player.volume_db = bgm_volume
		bgm_player.play()

func play_victory_fanfare() -> void:
	play_sfx("victory")

func resume_location_bgm() -> void:
	# After battle, resume the location's BGM
	current_bgm = ""  # Force re-evaluation
	var loc_type: String = LocationManager.current_location_data.get("type", "town")
	var mood: String = LocationManager.current_location_data.get("atmosphere", {}).get("music_mood", "")
	play_bgm_for_location(loc_type, mood)

func play_sfx(sfx_name: String) -> void:
	var path: String = "res://assets/audio/sfx/" + sfx_name + ".ogg"
	if not ResourceLoader.exists(path):
		path = "res://assets/audio/sfx/" + sfx_name + ".mp3"
	if not ResourceLoader.exists(path):
		path = "res://assets/audio/sfx/" + sfx_name + ".wav"
	if not ResourceLoader.exists(path):
		return
	var stream = load(path)
	if stream:
		sfx_player.stream = stream
		sfx_player.play()

func stop_bgm() -> void:
	bgm_player.stop()
	current_bgm = ""

extends Node

## Tier 2.6n — engine audio bus.
##
## Loads `res://data/sounds.json` at startup and synthesizes each entry
## into an AudioStreamWAV using sfxr-style procedural generation. Plays
## a sound by name via a pool of AudioStreamPlayers.
##
## Procedural-only for v1: no .ogg files in repo, no external deps.
## Future: GameShell autoload could prefer `audio/library/<name>.ogg`
## (gitignored generated files) when present, falling back to
## procedural — same `play(name)` API either way.
##
## Triggered by JSON rules via:
##   {"type": "emit_shell_event", "event": "play_sound", "name": "shoot"}
##
## GameShell drains shell events and calls AudioBus.play("shoot").
##
## Sound spec schema (data/sounds.json):
##   {
##     "sounds": {
##       "shoot": {
##         "wave": "square",          # square / sine / sawtooth / noise
##         "freq_start": 880,         # Hz
##         "freq_end": 220,           # Hz (interp linearly)
##         "duration": 0.15,          # seconds
##         "attack": 0.01,            # seconds — linear ramp-in
##         "decay": 0.6,              # 0=flat sustain, 1=fast decay
##         "volume": 0.5              # 0..1
##       }
##     }
##   }


const SR := 22050  # sample rate — adequate for arcade SFX, tiny memory
const POOL_SIZE := 8

var _cache: Dictionary = {}            # name → AudioStreamWAV
var _player_pool: Array = []           # AudioStreamPlayer pool


func _ready() -> void:
	for i in range(POOL_SIZE):
		var p := AudioStreamPlayer.new()
		add_child(p)
		_player_pool.append(p)
	_load_sounds_library()


func _load_sounds_library() -> void:
	var path := "res://data/sounds.json"
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return
	var raw := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(raw) != OK:
		push_warning("[AudioBus] sounds.json parse error: " + json.get_error_message())
		return
	if not (json.data is Dictionary): return
	var spec: Dictionary = json.data
	var sounds: Dictionary = spec.get("sounds", {})
	for sound_name in sounds.keys():
		var params = sounds[sound_name]
		if params is Dictionary:
			_cache[str(sound_name)] = _synthesize(params)


## sfxr-style PCM synthesis. Returns an AudioStreamWAV ready to play.
func _synthesize(p: Dictionary) -> AudioStreamWAV:
	var wave_type := str(p.get("wave", "square"))
	var freq_start := float(p.get("freq_start", 440))
	var freq_end := float(p.get("freq_end", freq_start))
	var duration := float(p.get("duration", 0.2))
	var attack := float(p.get("attack", 0.01))
	var decay := float(p.get("decay", 0.5))
	var volume := float(p.get("volume", 0.5))

	var n_samples := int(SR * duration)
	if n_samples <= 0: n_samples = 1
	var pcm := PackedByteArray()
	pcm.resize(n_samples * 2)

	var phase := 0.0
	for i in range(n_samples):
		var t: float = float(i) / float(SR)
		var t_frac: float = t / duration

		# Linear frequency interpolation
		var freq: float = lerp(freq_start, freq_end, t_frac)

		# Envelope: linear attack, then power-curve decay
		var env: float
		if t < attack:
			env = t / max(attack, 0.0001)
		else:
			var decay_t: float = (t - attack) / max(duration - attack, 0.0001)
			env = pow(1.0 - decay_t, 1.0 + decay * 4.0)
		env = clamp(env, 0.0, 1.0)

		# Waveform
		var s: float = 0.0
		match wave_type:
			"square":
				s = 1.0 if sin(phase) >= 0.0 else -1.0
			"sine":
				s = sin(phase)
			"sawtooth":
				s = fposmod(phase / TAU, 1.0) * 2.0 - 1.0
			"noise":
				s = randf_range(-1.0, 1.0)
			_:
				s = sin(phase)

		s *= env * volume
		var s16: int = int(clamp(s * 32767.0, -32767.0, 32767.0))
		# Pack signed 16-bit little-endian into unsigned byte slots
		var u16: int = s16 if s16 >= 0 else s16 + 65536
		pcm[i * 2] = u16 & 0xFF
		pcm[i * 2 + 1] = (u16 >> 8) & 0xFF

		phase += TAU * freq / float(SR)

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SR
	stream.stereo = false
	stream.data = pcm
	return stream


## Play a cached sound by name. Silent if name missing — never errors.
func play(sound_name: String) -> void:
	var stream = _cache.get(sound_name, null)
	if stream == null: return
	# Find a free player; preempt the oldest if all busy.
	for p in _player_pool:
		if not (p as AudioStreamPlayer).playing:
			(p as AudioStreamPlayer).stream = stream
			(p as AudioStreamPlayer).play()
			return
	(_player_pool[0] as AudioStreamPlayer).stop()
	(_player_pool[0] as AudioStreamPlayer).stream = stream
	(_player_pool[0] as AudioStreamPlayer).play()

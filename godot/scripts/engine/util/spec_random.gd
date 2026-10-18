extends RefCounted
class_name SpecRandom

## ADR 0095 — the one random generator of the spec. Every host uses the
## same algorithm, so a seed gives the same rolls on every host.
##
## - Generator: xoshiro128** (32-bit state words).
## - Seeding: four steps of a Weyl sequence (+0x9E3779B9), each mixed by
##   the murmur3 fmix32 function. An all-zero state becomes [1, 0, 0, 0].
## - randf() = (next_u32() >> 8) / 2^24, a float in [0, 1).
##
## spec/conformance/random_vectors.json holds the reference values.
## test_spec_random checks this file against them.
##
## The formula function `randf()` and the rule `chance` roll read
## `SpecRandom.shared`. World seeds it from scene.json `world_seed` (and
## `level_seed`), and a scenario can seed it with `seed`.

const MASK := 0xFFFFFFFF

static var shared: SpecRandom = SpecRandom.new(int(Time.get_ticks_usec()))

var _s: Array = [0, 0, 0, 0]


func _init(seed_value: int = 0) -> void:
	set_seed(seed_value)


func set_seed(seed_value: int) -> void:
	var x := seed_value & MASK
	for i in 4:
		x = (x + 0x9E3779B9) & MASK
		var z := x
		z = _mul32(z ^ (z >> 16), 0x85EBCA6B)
		z = _mul32(z ^ (z >> 13), 0xC2B2AE35)
		_s[i] = z ^ (z >> 16)
	if _s[0] == 0 and _s[1] == 0 and _s[2] == 0 and _s[3] == 0:
		_s[0] = 1


func next_u32() -> int:
	var result := _mul32(_rotl(_mul32(_s[1], 5), 7), 9)
	var t: int = (_s[1] << 9) & MASK
	_s[2] ^= _s[0]
	_s[3] ^= _s[1]
	_s[1] ^= _s[2]
	_s[0] ^= _s[3]
	_s[2] ^= t
	_s[3] = _rotl(_s[3], 11)
	return result


func randf() -> float:
	return float(next_u32() >> 8) / 16777216.0


## The low 32 bits of a * b. Split in 16-bit halves, so the product never
## leaves the 64-bit int range.
static func _mul32(a: int, b: int) -> int:
	var lo := a * (b & 0xFFFF)
	var hi := ((a * (b >> 16)) & 0xFFFF) << 16
	return (lo + hi) & MASK


static func _rotl(x: int, k: int) -> int:
	return ((x << k) | (x >> (32 - k))) & MASK

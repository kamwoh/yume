// Procedural audio with WebAudio (ADR 0095 phase 4). Mirrors audio_bus.gd
// and audio_channels.gd: each entry of sounds.json becomes PCM by the same
// sfxr-style synthesis, at the same 22050 Hz. A `notes` entry becomes a
// melody for the music slot. Eight voices play the one-shot sounds, and
// the oldest gives way. The channels are master, music and sfx (ADR 0090).
//
// A browser starts audio only after a user gesture. The first key or click
// resumes the audio context (unlock).
import { type Dict, isDict } from "../value.ts";

const SR = 22050;
const POOL_SIZE = 8;
const TAU = Math.PI * 2;

export class AudioBus {
  private ctx: AudioContext | null = null;
  private specs: Dict;
  private cache = new Map<string, AudioBuffer>();
  private channels = new Map<string, GainNode>();
  private voices: AudioBufferSourceNode[] = [];
  private music: AudioBufferSourceNode | null = null;
  private musicName = "";
  private cues: Dict;

  constructor(sounds: Dict, cues: Dict) {
    this.specs = isDict(sounds.sounds) ? sounds.sounds : {};
    this.cues = isDict(cues.cues) ? cues.cues : {};
  }

  /** Create or resume the audio context. Call it from a key or click handler. */
  unlock(): void {
    if (!this.ctx) {
      const AC = globalThis.AudioContext ?? (globalThis as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
      if (!AC) return;
      this.ctx = new AC();
      const master = this.ctx.createGain();
      master.connect(this.ctx.destination);
      this.channels.set("master", master);
      for (const ch of ["music", "sfx"]) {
        const g = this.ctx.createGain();
        g.connect(master);
        this.channels.set(ch, g);
      }
    }
    if (this.ctx.state === "suspended") void this.ctx.resume();
  }

  /** GameShell._resolve_at_ref for "@cues.<event>": the sound name of a semantic event. */
  resolve(name: string): string {
    if (!name.startsWith("@")) return name;
    if (name.startsWith("@cues.")) return String(this.cues[name.slice(6)] ?? "");
    return "";
  }

  /** AudioBus.play: a one-shot sound on the sfx channel. A missing name is silent. */
  play(name: string): void {
    const buf = this.buffer(this.resolve(name));
    if (!buf || !this.ctx) return;
    if (this.voices.length >= POOL_SIZE) this.voices.shift()?.stop();
    const src = this.ctx.createBufferSource();
    src.buffer = buf;
    src.connect(this.channels.get("sfx")!);
    src.onended = () => {
      const i = this.voices.indexOf(src);
      if (i >= 0) this.voices.splice(i, 1);
    };
    this.voices.push(src);
    src.start();
  }

  /** AudioBus.play_music: one looped sound on the music channel. The same name again is a no-op. */
  playMusic(name: string): void {
    const n = this.resolve(name);
    if (n === this.musicName && this.music) return;
    const buf = this.buffer(n);
    if (!buf || !this.ctx) return;
    this.stopMusic();
    const src = this.ctx.createBufferSource();
    src.buffer = buf;
    src.loop = true;
    src.connect(this.channels.get("music")!);
    src.start();
    this.music = src;
    this.musicName = n;
  }

  stopMusic(): void {
    this.music?.stop();
    this.music = null;
    this.musicName = "";
  }

  /** EffectShell.set_audio_bus_volume: a linear level in [0, 1] for one channel. */
  setVolume(channel: string, linear: number): void {
    const g = this.channels.get(channel);
    if (g) g.gain.value = Math.min(Math.max(linear, 0), 1);
    else if (!["master", "music", "sfx"].includes(channel)) console.warn(`[audio] '${channel}' is not an audio channel (ADR 0090)`);
  }

  /** A shell event: play_sound, play_music or stop_music. */
  event(ev: Dict): void {
    switch (String(ev.event ?? ev.type ?? "")) {
      case "play_sound":
        this.play(String(ev.name ?? ""));
        break;
      case "play_music":
        this.playMusic(String(ev.name ?? ""));
        break;
      case "stop_music":
        this.stopMusic();
        break;
      case "set_audio_bus_volume":
        this.setVolume(String(ev.bus ?? "master"), Number(ev.linear ?? 1));
        break;
    }
  }

  private buffer(name: string): AudioBuffer | null {
    if (name === "" || !this.ctx) return null;
    const hit = this.cache.get(name);
    if (hit) return hit;
    const spec = this.specs[name];
    if (!isDict(spec)) return null;
    const pcm = Array.isArray(spec.notes) ? synthesizeMelody(spec) : synthesize(spec);
    const buf = this.ctx.createBuffer(1, Math.max(pcm.length, 1), SR);
    buf.getChannelData(0).set(pcm);
    this.cache.set(name, buf);
    return buf;
  }
}

/** AudioBus._synthesize: a sweep from freq_start to freq_end, a linear attack, then a power-curve decay. */
export function synthesize(p: Dict): Float32Array {
  const wave = String(p.wave ?? "square");
  const f0 = Number(p.freq_start ?? 440);
  const f1 = Number(p.freq_end ?? f0);
  const dur = Number(p.duration ?? 0.2);
  const attack = Number(p.attack ?? 0.01);
  const decay = Number(p.decay ?? 0.5);
  const volume = Number(p.volume ?? 0.5);
  const n = Math.max(Math.trunc(SR * dur), 1);
  const out = new Float32Array(n);
  let phase = 0;
  for (let i = 0; i < n; i++) {
    const t = i / SR;
    const freq = f0 + (f1 - f0) * (t / dur);
    let env = t < attack ? t / Math.max(attack, 0.0001) : Math.pow(1 - (t - attack) / Math.max(dur - attack, 0.0001), 1 + decay * 4);
    env = Math.min(Math.max(env, 0), 1);
    out[i] = quantize(sample(wave, phase) * env * volume);
    phase += (TAU * freq) / SR;
  }
  return out;
}

/** AudioBus._synthesize_melody: notes {freq, dur, wave?, volume?} in a row, each with a pluck envelope. */
export function synthesizeMelody(p: Dict): Float32Array {
  const defWave = String(p.wave ?? "sine");
  const defVol = Number(p.volume ?? 0.4);
  const parts: number[] = [];
  for (const note of Array.isArray(p.notes) ? p.notes : []) {
    if (!isDict(note)) continue;
    const freq = Number(note.freq ?? 440);
    const dur = Number(note.dur ?? 0.4);
    const wave = String(note.wave ?? defWave);
    const vol = Number(note.volume ?? defVol);
    const n = Math.trunc(SR * dur);
    let phase = 0;
    for (let i = 0; i < n; i++) {
      const tf = i / SR / Math.max(dur, 0.001);
      const env = tf < 0.05 ? tf / 0.05 : Math.pow(1 - (tf - 0.05) / 0.95, 2);
      parts.push(quantize(sample(wave, phase) * env * vol));
      phase += (TAU * freq) / SR;
    }
  }
  return new Float32Array(parts);
}

function sample(wave: string, phase: number): number {
  switch (wave) {
    case "square":
      return Math.sin(phase) >= 0 ? 1 : -1;
    case "sawtooth":
      return (((phase / TAU) % 1) + 1) % 1 * 2 - 1;
    case "noise":
      // Presentation only: the spec generator stays for the sim (ADR 0095).
      return Math.random() * 2 - 1;
  }
  return Math.sin(phase);
}

/** The 16-bit PCM of the reference, back to a float. */
function quantize(s: number): number {
  return Math.trunc(Math.min(Math.max(s * 32767, -32767), 32767)) / 32767;
}

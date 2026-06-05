# Installing & running Yume

> **Read this first.** Yume was written **entirely by Claude** and is designed to
> be **read and operated by Claude**. The intended way to use it is to open the
> repo in **Claude Code** and ask, in plain English, for what you want — Claude
> knows the build/run conventions (they live in `CLAUDE.md` + `.claude/`). You
> *can* run the commands below yourself, but it's easy to get the
> invocation wrong (e.g. the `cd "$TEMPLATE_DST" && --path .` trap). Letting
> Claude drive is the recommended, lower-friction path.

---

## 1. What you need

| Requirement | Why | Notes |
|---|---|---|
| **Godot 4.6.1.stable** | the engine | build `14d19694e`, `gl_compatibility` renderer. Pinned — see `docs/engine-reference/godot/VERSION.md`. |
| **Python 3.10+** (a venv) | the authoring/tooling side (asset gen, visual QA, layout pipelines, net-video) | the engine needs no Python; only the `tools/`+`scripts/` Python does. |
| **ffmpeg** | stitch frames → mp4 (net-video) | `apt install ffmpeg` / `brew install ffmpeg` |
| **rsync** | sync framework → Godot project dir | usually preinstalled |
| **Xvfb + Mesa GL** *(Linux/WSL, optional)* | headless rendering (`--linux` video mode, CI) | `apt install xvfb libgl1-mesa-dri libegl1` |
| **WSL2** *(Windows only)* | run the Linux tooling + Claude Code | the repo was developed under WSL2 (Ubuntu). |

---

## 2. Get Godot

Download **Godot 4.6.1.stable** (standard build, not .NET/Mono) from
<https://godotengine.org/download/archive/> — grab the binary(ies) for how you'll
run it:

- **Windows binary** (`Godot_v4.6.1-stable_win64.exe`) — used by `scripts/play.sh`
  (the authoritative play/capture/test path; runs the `.exe` from WSL).
- **Linux binary** (`Godot_v4.6.1-stable_linux.x86_64`) — used by
  `scripts/run_linux.sh` and the Python env (fast headless tests, the net-video
  `--linux` mode).

You can use either or both. Then point Yume at them with env vars (defaults are
the author's machine paths, so **set your own**):

```bash
# Windows binary + a writable "template" copy of the project it runs:
export YUME_GODOT_BIN="/path/to/Godot_v4.6.1-stable_win64.exe"
export YUME_TEMPLATE_DST="/path/to/YumeTemplate"      # any empty dir; play.sh syncs into it

# Linux binary + its project dir (for run_linux.sh / net_video --linux):
export YUME_GODOT_LINUX_BIN="/path/to/Godot_v4.6.1-stable_linux.x86_64"
export YUME_GODOT_LINUX_PROJECT="$HOME/godot-linux/yume"
```

(Put these in your shell profile so Claude's commands pick them up.)

---

## 3. Python tooling

```bash
cd yume
python3 -m venv venv
venv/bin/pip install -r requirements.txt
```

If you'll generate assets, also export the relevant API keys (`OPENAI_API_KEY`,
`TRIPO_API_KEY`, `GEMINI_API_KEY`). None are needed to just run/play existing
content.

---

## 4. Running it — the recommended way (ask Claude)

Open the repo in **Claude Code** and ask in natural language. Examples:

> *"Generate a game from this pitch: a roguelike where vampires steal HP from
> light sources."*  → Claude runs the `/yume-design` pipeline.

> *"Run the engine unit tests and tell me if anything fails."*

> *"Record a 4-player synced multiplayer video, headless."*  → Claude runs the
> net-video recorder (`--linux`, smooth, GPU) and hands you the mp4 path.

> *"Play `demo_tiny_village` and capture a frame so we can review it."*

Claude reads `CLAUDE.md` + `.claude/rules/` and handles the fiddly bits (syncing
to the template, `cd` + `--path .`, importing new assets, the visual-QA gate,
etc.). **This is the intended workflow** — you describe the goal; Claude operates
the framework.

---

## 5. Running it yourself (manual fallback)

If you want to drive it directly:

```bash
# Play / capture a locally-generated demo (Windows binary):
./scripts/play.sh <name>
./scripts/play.sh <name> --capture

# Headless tests via the Linux binary:
./scripts/run_linux.sh test

# Record a synced N-player video (headless, no window):
CLIENTS=4 SECS=6 venv/bin/python scripts/net_video.py demo_tiny_village --linux
```

⚠️ Gotchas (the reason Claude is recommended): Godot runs must `cd` **into** the
template dir and use `--path .` — an absolute `--path /mnt/c/...` silently aborts
with no test output. New `class_name` scripts need a `--import` pass first. See
`CLAUDE.md` § "Running Godot" for the full, exact workflow.

---

## 6. Demos are not in git

Per-game content (`godot/data/demo_<name>/`) is **gitignored** — generate it
locally via `/yume-design` (ask Claude), or copy a `demo_<name>/` folder from
another working tree. The repo ships the **framework** (engine, skills, shared
libs), not specific games.

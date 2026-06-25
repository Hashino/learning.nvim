#!/usr/bin/env bash
# Regenerate a README demo GIF from a demo tape.
#
# Each demo lives in its own subdirectory under demos/:
#   demos/<name>/<name>.tape   the VHS script driving the recorded session
#   demos/<name>/<name>.c      the code file nvim opens (the canonical seed)
#   demos/<name>/<name>.gif    the generated output the README embeds
# with a shared demos/init.lua (the headless nvim config) and this record.sh.
#
# Usage:
#   ./record.sh            # records the default demo (drill)
#   ./record.sh drill      # records demos/drill/drill.tape -> demos/drill/drill.gif
#
# Provider: export a mercury API key for the fast endpoint, OR leave it unset to
# use the free, keyless provider (init.lua falls back to it). The free provider is
# SLOWER, which actually showcases the loading spinner/notifications better — a
# near-instant model barely shows them. The key is NOT stored in the repo:
#   export LEARNING_API_KEY=sk_...   ./record.sh drill   # fast mercury
#   ./record.sh drill                                    # free keyless provider
#
# Tunables (env): TAPE (default <name>.tape), OUT (default <name>.gif),
#   LEARNING_API_URL / LEARNING_MODEL (default to mercury when a key is set).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEMO="${1:-drill}"
demo_dir="$here/$DEMO"
[[ -d "$demo_dir" ]] || { echo "error: no demo directory $demo_dir" >&2; exit 1; }

TAPE="${TAPE:-$DEMO.tape}"
OUT="${OUT:-$demo_dir/$DEMO.gif}"
FPS="${FPS:-15}"
WIDTH="${WIDTH:-1280}"
mp4="$demo_dir/$DEMO.mp4"   # VHS records here; ffmpeg converts it to $OUT
[[ -f "$demo_dir/$TAPE" ]] || { echo "error: no tape $demo_dir/$TAPE" >&2; exit 1; }
# the source file the tape opens: $DEMO.<ext> — the only $DEMO.* that isn't a
# build artifact (.tape/.gif/.mp4). language-agnostic so a demo can be C/Rust/Lua.
code="$(find "$demo_dir" -maxdepth 1 -type f -name "$DEMO.*" \
  ! -name '*.tape' ! -name '*.gif' ! -name '*.mp4' | head -n1)"
[[ -n "$code" ]] || { echo "error: no source file $demo_dir/$DEMO.<ext>" >&2; exit 1; }

# --- isolate XDG_DATA_HOME for the demo ------------------------------------
# Use a temp directory so the demo's learning.nvim data doesn't pollute
# the user's real data and each run starts from a clean "beginner" state.
DEMO_XDG_DATA="$(mktemp -d)"
export XDG_DATA_HOME="$DEMO_XDG_DATA"

# Optionally seed learning.nvim's progress so a feature gated above the default
# "beginner" tier (e.g. an intermediate idiom) is actually unlocked and gets
# taught. A demo that needs it ships demos/<name>/progress.json.
if [[ -f "$demo_dir/progress.json" ]]; then
  seed_dir="$DEMO_XDG_DATA/nvim/learning.nvim"
  mkdir -p "$seed_dir"
  cp "$demo_dir/progress.json" "$seed_dir/progress.json"
fi

# --- isolate XDG_CONFIG_HOME for the demo ------------------------------------
# Use a temp directory so the demo doesn't load the user's nvim config.
# Populate it with the demo's shared init.lua.
DEMO_XDG_CONFIG="$(mktemp -d)"
mkdir -p "$DEMO_XDG_CONFIG/nvim"
cp "$here/init.lua" "$DEMO_XDG_CONFIG/nvim/init.lua"
export XDG_CONFIG_HOME="$DEMO_XDG_CONFIG"
pal=""   # palette temp file; referenced by the trap below
trap 'rm -rf "$DEMO_XDG_DATA" "$DEMO_XDG_CONFIG"; rm -f "${pal:-}"' EXIT

# init.lua is copied into the temp config above, so it can't resolve the plugin
# root from its own (temp) path. Hand it the real repo root — the dir containing
# this demos/ folder — via the environment instead.
export LEARNING_PLUGIN_ROOT="$(dirname "$here")"

# --- preflight -------------------------------------------------------------
command -v vhs    >/dev/null || { echo "error: vhs not found (https://github.com/charmbracelet/vhs)"   >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "error: ffmpeg not found" >&2; exit 1; }
if [[ -n "${LEARNING_API_KEY:-}" ]]; then
  # a key is set: pass through all three env vars to init.lua
  # LEARNING_API_URL, LEARNING_MODEL, LEARNING_API_KEY must all be set
  if [[ -z "${LEARNING_API_URL:-}" || -z "${LEARNING_MODEL:-}" ]]; then
    echo "error: LEARNING_API_KEY is set but LEARNING_API_URL and/or LEARNING_MODEL are missing" >&2
    echo "       all three must be set together for a custom provider" >&2
    exit 1
  fi
  export LEARNING_API_URL LEARNING_MODEL LEARNING_API_KEY
  provider_desc="$LEARNING_MODEL"
else
  # no key: init.lua falls back to the free, keyless provider (slower, but it
  # showcases the loading spinner/notifications better).
  provider_desc="free keyless provider"
fi

# --- 1. reset the demo file ------------------------------------------------
# The tape starts from an empty file and types everything itself, so reset to a
# fresh empty file — this also undoes any content an interrupted/saved previous
# run left behind.
echo "==> resetting $(basename "$code") (empty)"
rm -f "$code"
touch "$code"
rm -f "$HOME/.local/state/nvim/swap"/*"$(basename "$code").swp" 2>/dev/null || true

# --- 2. record -------------------------------------------------------------
# The tape writes MP4, not GIF. A demo that waits on a live AI runs long, and
# VHS's direct GIF encode holds the whole frame sequence for the palette pass —
# a long high-res GIF can exhaust memory and silently produce a 0-byte file
# (VHS doesn't check ffmpeg's exit code). MP4 (a streaming H.264 encode) avoids
# that; we convert to GIF below with capped fps/scale.
echo "==> recording $TAPE with VHS (drives nvim + the live AI: ${provider_desc})…"
( cd "$demo_dir" && vhs "$TAPE" )
[[ -s "$mp4" ]] || { echo "error: VHS did not produce $mp4" >&2; exit 1; }

# --- 3. convert mp4 -> gif -------------------------------------------------
# Two passes (palette to a temp file, then apply) instead of the split[a][b]
# one-liner: the split form buffers two full scaled streams at once and OOMs on
# long 720p recordings. Two passes keep peak memory low.
echo "==> converting to GIF (${WIDTH}px @ ${FPS}fps)…"
pal="$(mktemp --suffix=.png)"
ffmpeg -y -loglevel error -i "$mp4" \
  -vf "fps=${FPS},scale=${WIDTH}:-1:flags=lanczos,palettegen=stats_mode=diff" "$pal"
ffmpeg -y -loglevel error -i "$mp4" -i "$pal" \
  -lavfi "fps=${FPS},scale=${WIDTH}:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5" \
  "$OUT"
rm -f "$pal"

# --- 4. finish -------------------------------------------------------------
[[ "${KEEP_MP4:-0}" == 1 ]] || rm -f "$mp4"
echo "==> done: $OUT ($(du -h "$OUT" | cut -f1))"

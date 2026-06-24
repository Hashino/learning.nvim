#!/usr/bin/env bash
# Regenerate the README demo GIF from demo.tape.
#
#   1. reset the demo file (demo.c) to a known state
#   2. record the tape with VHS  ->  demo.mp4  (MP4 = light, never 0 bytes)
#   3. convert the MP4 to a GIF with ffmpeg (capped fps/scale so the palette
#      pass stays small)
#   4. write the result to demo/demo.gif (what the README embeds)
#
# Provider: export a mercury API key for the fast endpoint, OR leave it unset to
# use the free, keyless provider (init.lua falls back to it). The free provider is
# SLOWER, which actually showcases the loading spinner/notifications better — a
# near-instant model barely shows them. The key is NOT stored in the repo:
#   export LEARNING_API_KEY=sk_...   ./demo/record.sh   # fast mercury
#   ./demo/record.sh                                    # free keyless provider
#
# Tunables (env): TAPE (default demo.tape), OUT (default <tape>.gif), FPS (30),
#   WIDTH (1920), LEARNING_API_URL / LEARNING_MODEL (default to mercury when a
#   key is set).
#
# To test GIF quality cheaply before the full run, record the explain-only tape
# through this same conversion pass:
#   TAPE=explain-test.tape ./demo/record.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TAPE="${TAPE:-demo.tape}"
base="$(basename "${TAPE%.tape}")"   # e.g. demo / explain-test
OUT="${OUT:-$here/$base.gif}"
FPS="${FPS:-30}"
WIDTH="${WIDTH:-1920}"
mp4="$here/$base.mp4"

# --- preflight -------------------------------------------------------------
command -v vhs    >/dev/null || { echo "error: vhs not found (https://github.com/charmbracelet/vhs)"   >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "error: ffmpeg not found" >&2; exit 1; }
if [[ -n "${LEARNING_API_KEY:-}" ]]; then
  # a key is set: point init.lua's env_provider at the fast mercury endpoint
  # (non-secret coordinates, safe to commit) and export all three so it's used.
  export LEARNING_API_URL="${LEARNING_API_URL:-https://api.inceptionlabs.ai/v1/chat/completions}"
  export LEARNING_MODEL="${LEARNING_MODEL:-mercury-2}"
  export LEARNING_API_KEY
  provider_desc="$LEARNING_MODEL"
else
  # no key: init.lua falls back to the free, keyless provider (slower, but it
  # showcases the loading spinner/notifications better).
  provider_desc="free keyless provider"
fi

# --- 1. reset the demo file ------------------------------------------------
# The tape quits with :qa! (no save), but reset anyway so an interrupted or
# manually-saved run never leaves stale content for the next recording.
echo "==> resetting demo/demo.c"
cat > "$here/demo.c" <<'EOF'
#include <stddef.h>

// sum of all elements in arr
long sum(const int *arr, size_t len) {
    long total = 0;
    for (size_t i = 0; i < len; i++) {
        total += arr[i];
    }
    return total;
}
EOF
rm -f "$HOME/.local/state/nvim/swap"/*demo.c.swp 2>/dev/null || true

# --- 1b. isolate the plugin's saved progress -------------------------------
# learning.nvim persists per-language skill progress + dismissals under
# stdpath('data')/learning.nvim. That's the USER's real data — letting the demo
# mutate it would corrupt their progress AND make the recording non-deterministic
# (features become "known"/suppressed across runs, silently changing the
# suggestion cascade). Move it aside so every recording starts from a clean
# "beginner, nothing known" state, and restore it on exit (any path).
pal=""   # set later; referenced by the shared trap below
ldir="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/learning.nvim"
lbak=""
if [[ -d "$ldir" ]]; then
  lbak="$(mktemp -d)/learning.nvim"
  mv "$ldir" "$lbak"
  echo "==> moved your learning.nvim progress aside (restored on exit)"
fi
restore_state() {
  if [[ -n "$lbak" && -d "$lbak" ]]; then rm -rf "$ldir"; mv "$lbak" "$ldir"; fi
}
trap 'rm -f "${pal:-}"; restore_state' EXIT

# --- 2. record -------------------------------------------------------------
echo "==> recording $TAPE with VHS (drives nvim + the live AI: ${provider_desc})…"
( cd "$here" && vhs "$TAPE" )
[[ -s "$mp4" ]] || { echo "error: VHS did not produce $mp4" >&2; exit 1; }

# --- 3. convert mp4 -> gif -------------------------------------------------
# Two passes (palette to a temp file, then apply) instead of the split[a][b]
# one-liner: the split form buffers two full scaled streams at once and OOMs on
# long 1080p@30 recordings. Two passes keep peak memory low.
echo "==> converting to GIF (${WIDTH}px @ ${FPS}fps)…"
pal="$(mktemp --suffix=.png)"
ffmpeg -y -loglevel error -i "$mp4" \
  -vf "fps=${FPS},scale=${WIDTH}:-1:flags=lanczos,palettegen=stats_mode=diff" "$pal"
ffmpeg -y -loglevel error -i "$mp4" -i "$pal" \
  -lavfi "fps=${FPS},scale=${WIDTH}:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5" \
  "$OUT"

# --- 4. finish -------------------------------------------------------------
[[ "${KEEP_MP4:-0}" == 1 ]] || rm -f "$mp4"
echo "==> done: $OUT ($(du -h "$OUT" | cut -f1))"

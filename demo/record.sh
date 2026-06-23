#!/usr/bin/env bash
# Regenerate the README demo GIF from demo.tape.
#
#   1. reset the demo file (demo.c) to a known state
#   2. record the tape with VHS  ->  demo.mp4  (MP4 = light, never 0 bytes)
#   3. convert the MP4 to a GIF with ffmpeg (capped fps/scale so the palette
#      pass stays small)
#   4. write the result to demo/demo.gif (what the README embeds)
#
# The mercury API key is NOT stored in the repo — export it first:
#   export LEARNING_API_KEY=sk_...
#   ./demo/record.sh
# (Without it, init.lua falls back to the free test provider — slower, so the
# recording's sleeps may need to be longer.)
#
# Tunables (env): OUT (default demo/demo.gif), FPS (15), WIDTH (1280),
#   LEARNING_API_URL / LEARNING_MODEL (default to mercury, below).
set -euo pipefail

# Non-secret provider coordinates — safe to commit. Override via env if desired.
export LEARNING_API_URL="${LEARNING_API_URL:-https://api.inceptionlabs.ai/v1/chat/completions}"
export LEARNING_MODEL="${LEARNING_MODEL:-mercury-2}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUT="${OUT:-$here/demo.gif}"
FPS="${FPS:-15}"
WIDTH="${WIDTH:-1280}"
mp4="$here/demo.mp4"

# --- preflight -------------------------------------------------------------
command -v vhs    >/dev/null || { echo "error: vhs not found (https://github.com/charmbracelet/vhs)"   >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "error: ffmpeg not found" >&2; exit 1; }
if [[ -z "${LEARNING_API_KEY:-}" ]]; then
  echo "error: LEARNING_API_KEY is not set. Export your mercury key first:" >&2
  echo "       export LEARNING_API_KEY=sk_..." >&2
  exit 1
fi
export LEARNING_API_KEY   # make it visible to the nvim that VHS launches

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

# --- 2. record -------------------------------------------------------------
echo "==> recording demo.tape with VHS (drives nvim + the live mercury AI)…"
( cd "$here" && vhs demo.tape )
[[ -s "$mp4" ]] || { echo "error: VHS did not produce $mp4" >&2; exit 1; }

# --- 3. convert mp4 -> gif -------------------------------------------------
echo "==> converting to GIF (${WIDTH}px @ ${FPS}fps)…"
ffmpeg -y -loglevel error -i "$mp4" \
  -vf "fps=${FPS},scale=${WIDTH}:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5" \
  "$OUT"

# --- 4. finish -------------------------------------------------------------
[[ "${KEEP_MP4:-0}" == 1 ]] || rm -f "$mp4"
echo "==> done: $OUT ($(du -h "$OUT" | cut -f1))"

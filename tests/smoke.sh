#!/usr/bin/env bash
# Comprehensive single-session end-to-end test for learning.nvim, driven through
# a REAL Neovim via tui-use. This is the mandatory final step of the suite: it
# exercises the whole plugin in one session — the keystroke -> autocmd ->
# debounce -> window -> keymap path the headless runner (tests/run.lua) can't.
#
# Usage:
#   tests/smoke.sh [config]
# `config` defaults to tests/init.lua (keyless free Zen). Pass a faster personal
# config (e.g. custom_nvim_config/init.lua) to speed up the live model calls.
#
# Requires the tui-use CLI on PATH. Exits non-zero on any failed behaviour.

set -u
CONFIG="${1:-tests/init.lua}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SAMPLE=/tmp/learning-smoke.py
export XDG_DATA_HOME=/tmp/learning-smoke-data # isolate dismissal state

if ! command -v tui-use >/dev/null 2>&1; then
  echo "tui-use CLI not found on PATH" >&2
  exit 2
fi

pass=0
fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; fail=$((fail + 1)); }

cleanup() {
  tui-use kill >/dev/null 2>&1
  tui-use daemon stop >/dev/null 2>&1
  rm -f "$SAMPLE" ~/.local/state/nvim/swap/*learning-smoke* 2>/dev/null
  rm -rf "$XDG_DATA_HOME"
}
trap cleanup EXIT

# a suggestion/explain window is on screen iff its winbar (which ends in "dismiss")
# is. the drill HUD's winbar says "keep & stop" instead, so this matches only the
# focused suggestion/explain windows — and never the ":Learning ..." cmdline echo.
# (the drill's own keystrokes use <S-CR>/<C-g>, which terminals can't reliably
# send, so the learn->drill path is covered deterministically in tests/run.lua.)
win_open() { tui-use find "dismiss" 2>/dev/null | grep -q "Found"; }
on_screen() { tui-use find "$1" 2>/dev/null | grep -q "Found"; }
wait_win() { tui-use wait --text "dismiss" "${1:-75000}" >/dev/null 2>&1; }
settle() { tui-use wait "${1:-5000}" >/dev/null 2>&1; }
dismiss() {
  tui-use press escape >/dev/null 2>&1
  tui-use wait 600 >/dev/null 2>&1
}
edit() { # type keys, leave insert/visual, let the debounce arm
  tui-use type "$1" >/dev/null 2>&1
  tui-use press escape >/dev/null 2>&1
}
# Re-arm a suggestion up to N times to ride out the free model's per-call drop
# rate. Each attempt types a FRESH edit (the template's %d is the attempt number),
# because the snapshot advances after every request — so a repeated *identical*
# edit produces no new diff, but a slightly different one always does. Returns 0
# as soon as a window opens.
retry_win() { # <attempts> <printf-template-with-%d>
  local attempts="$1" tmpl="$2" i editcmd
  for ((i = 1; i <= attempts; i++)); do
    # shellcheck disable=SC2059
    printf -v editcmd "$tmpl" "$i"
    edit "$editcmd"
    wait_win 75000
    win_open && return 0
  done
  return 1
}

# fresh fixture and dismissal state
rm -rf "$XDG_DATA_HOME"
rm -f ~/.local/state/nvim/swap/*learning-smoke* 2>/dev/null

# pre-unlock every skill tier for python, so this PATH test exercises the
# keystroke -> window plumbing without the progressive gate hiding suggestions
# (progression itself is covered deterministically in tests/run.lua).
mkdir -p "$XDG_DATA_HOME/nvim/learning.nvim"
printf '{"python":{"level":"advanced","knows":{}}}' \
  >"$XDG_DATA_HOME/nvim/learning.nvim/progress.json"
cat >"$SAMPLE" <<'PY'
def total(numbers):
    result = 0
    for n in numbers:
        result = result + n
    return result
PY

# --- startup ---
tui-use start --cols 90 --rows 30 --cwd "$ROOT" \
  "env XDG_DATA_HOME=$XDG_DATA_HOME nvim -n -u $CONFIG $SAMPLE" >/dev/null 2>&1
tui-use wait --text "def total" 10000 >/dev/null 2>&1
tui-use press enter >/dev/null 2>&1
tui-use wait 800 >/dev/null 2>&1
on_screen "def total" && ok "startup: buffer loads, no fatal config error" \
  || bad "startup: buffer loads, no fatal config error"

# --- explain with no selection (must run before any visual mode is used) ---
tui-use type ":Learning explain" >/dev/null 2>&1
tui-use press enter >/dev/null 2>&1
tui-use wait 1500 >/dev/null 2>&1
on_screen "no visual selection" && ok "explain: no selection notifies" \
  || bad "explain: no selection notifies"
tui-use press escape >/dev/null 2>&1

# --- edit detection: a trivial reindent must NOT trigger a suggestion ---
tui-use type "2GV2j>" >/dev/null 2>&1
tui-use type "gv<" >/dev/null 2>&1
tui-use press escape >/dev/null 2>&1
settle 5000
win_open && bad "edit-detection: trivial reindent shows no window" \
  || ok "edit-detection: trivial reindent shows no window"

# --- auto-suggestion: a meaningful edit triggers a window ---
# append a genuine beginner miss the model reliably teaches (slicing the whole
# list); retry to ride out dropped calls. (Idiomatic code and comments classify
# as "none" and correctly show nothing — so triggers must be real misses.)
retry_win 4 'Goseg%d = numbers[0:len(numbers)]' \
  && ok "auto-suggestion: meaningful edit opens a window" \
  || bad "auto-suggestion: meaningful edit opens a window"
dismiss

# --- dismissal suppression: same feature (negative indexing) past threshold (2) ---
retry_win 4 'ggOlast%d = numbers[len(numbers) - 1]' \
  && ok "suppression: miss suggestion #1 shows" \
  || bad "suppression: miss suggestion #1 shows"
dismiss
retry_win 4 'ggOprev%d = numbers[len(numbers) - 2]' \
  && ok "suppression: miss suggestion #2 shows" \
  || bad "suppression: miss suggestion #2 shows"
dismiss
edit "ggOmid = numbers[len(numbers) - 3]"
settle 10000
win_open && bad "suppression: feature suppressed after threshold" \
  || ok "suppression: feature suppressed after threshold"

# --- explain a real visual selection -> relevant answer ---
# insert a distinctive construct (an f-string, a DIFFERENT feature from the list
# comprehensions above, so it can't push "list comprehension" past the dismiss
# threshold); dismiss any auto-suggestion it triggers.
edit 'Golabel = f"n={len(numbers)}"'
wait_win 20000
dismiss
# assert the real selection -> explain -> window PATH works (marks + visualmode
# the headless runner can't drive). content relevance is asserted against the raw
# response in tests/run.lua, not by scraping the wrapped float. retry the explain
# call to ride out dropped responses.
explained=1
for _ in 1 2 3 4; do
  tui-use type "GV" >/dev/null 2>&1 # linewise-select the comprehension line
  tui-use wait 400 >/dev/null 2>&1
  tui-use type ":Learning explain" >/dev/null 2>&1
  tui-use press enter >/dev/null 2>&1
  wait_win 75000
  if win_open; then explained=0; break; fi
  tui-use press escape >/dev/null 2>&1
done
[ "$explained" -eq 0 ] && ok "explain: real visual selection opens an explanation window" \
  || bad "explain: real visual selection opens an explanation window"
dismiss

# --- disable / enable ---
tui-use type ":Learning disable" >/dev/null 2>&1
tui-use press enter >/dev/null 2>&1
tui-use wait 500 >/dev/null 2>&1
edit "Godis = numbers[0:len(numbers)]"
settle 6000
win_open && bad "disable: no suggestion while disabled" \
  || ok "disable: no suggestion while disabled"
tui-use type ":Learning enable" >/dev/null 2>&1
tui-use press enter >/dev/null 2>&1
tui-use wait 500 >/dev/null 2>&1
retry_win 4 'Goend%d = numbers[0:len(numbers)]' \
  && ok "enable: suggestions resume after re-enabling" \
  || bad "enable: suggestions resume after re-enabling"
dismiss

echo "============================================================"
echo "SMOKE RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

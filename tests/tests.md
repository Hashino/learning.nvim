# learning.nvim — test suite

**When to run.** After a **big change to the main logic** — edit detection, the
prompt / tool-call shape, skill-level classification/gating, or dismissal
suppression. Skip it for docs, config defaults, or small refactors.

## Automated suite (primary)

[`tests/run.lua`](run.lua) drives the real plugin end-to-end against whatever
provider the launching config sets up, prints `PASS`/`FAIL` per check, and exits
non-zero on any failure. **Run it 3 times; it should pass every time** — the value
of repeating is catching model-dependent flicker.

```sh
# keyless free Zen (no API key needed) — the default
XDG_DATA_HOME=/tmp/learning-test nvim --headless \
  -u tests/init.lua -c "luafile tests/run.lua"

# any personal provider
XDG_DATA_HOME=/tmp/learning-test nvim --headless \
  -u custom_nvim_config/init.lua -c "luafile tests/run.lua"
```

The live model-dependent checks fire **concurrently** (one request each) and
retry transient failures in a few waves, so the suite isn't bottlenecked on slow
sequential calls. Use a **fresh** `XDG_DATA_HOME` each run: it isolates dismissal
*and* per-language skill-progress storage in a throwaway dir (so your real
`~/.local/share/nvim/learning.nvim/` is untouched), and a clean dir is what lets
the progression probes start from the lowest level.

### What it covers

- **Edit detection** (deterministic) — reindent, blank-line churn, and pure
  deletions never suggest; a top-of-file insertion stays localized to the changed
  line instead of flagging the whole file.
- **Edit validation** — malformed model edits are rejected before being applied.
- **Window policy** — accepting applies the edit to the buffer; a tracked dismiss
  records toward suppression; an untracked dismiss and an explain-style dismiss do
  **not** record.
- **Dismissal suppression** — a feature is suppressed once it reaches
  `dismiss_threshold`.
- **Skill-level gate + progression** (deterministic) — a language starts at
  `beginner`; only levels at/below the unlocked one show; engaging with
  `unlock_threshold` suggestions *at the current top level* unlocks the next one
  (and only top-level engagement counts); progress is per-language and persists
  across reloads, capped at `master`.
- **Explain, no selection** — `Learning.explain()` with nothing selected notifies
  and opens no window.
- **Auto-suggestion** — returns a result relevant to the edited lines, classified
  with a known skill `level` and a well-formed edit.
- **Level ordering (live)** — curated fixtures grouped by level
  (`fixtures.CURATED`) classify in roughly increasing order: the `beginner`
  cluster lands lowest, `master` highest, with the middles in between. Printed as
  `INFO  level classification: ...` every run.
- **Explain, relevance** — explaining a distinctive construct names it (a list
  comprehension → "comprehension").

### Why an *ordering* check, and why three runs

The classification a weak model assigns is noisy run-to-run, especially in the
middle (`intermediate` vs `advanced`). So the live check asserts the robust shape
rather than an exact per-fixture level: the **easy extreme classifies lowest and
the hard extreme highest, with a clear total spread**. Running the suite three
times (and reading the printed `INFO level classification` line) shows whether the
ordering holds reliably. If the extremes don't separate, the suspect is the
model's `level` rubric (prompt/tool), not the gate — which is exercised
deterministically above.

### Model reliability

`make_ai_request` retries a few times (`MAX_ATTEMPTS` in `lua/learning/ai.lua`) on
a transient empty/unparseable response, and the live suite additionally retries
dropped calls across concurrent waves, so an occasional missing tool call doesn't
fail an otherwise-correct run. If a provider still makes the suite flicker a lot,
its tool-calling is unreliable — try a stronger model before suspecting the plugin.

## End-to-end smoke (tui-use) — always run this last

The headless runner calls plugin functions directly, so it never exercises the
real `keystroke → autocmd → debounce → window → keymap` path. [`tests/smoke.sh`](smoke.sh)
closes that gap: it drives **one real Neovim session** through every behaviour and
asserts each. **Always finish a suite run with it.**

```sh
tests/smoke.sh                          # keyless free Zen (tests/init.lua)
tests/smoke.sh custom_nvim_config/init.lua   # faster personal provider
```

It needs the `tui-use` CLI on `PATH`, runs in a small terminal to stay cheap,
isolates dismissal state via `XDG_DATA_HOME`, prints `PASS`/`FAIL` per behaviour,
and exits non-zero on any failure. In one session it covers:

- startup with no fatal config error
- `:Learning explain` with no selection → notifies
- a trivial reindent → **no** window (edit detection)
- a meaningful edit → a suggestion window opens
- the dismissal cycle: same feature shows twice, then is suppressed at the threshold
- `:Learning explain` on a real visual selection → an explanation window opens
- `:Learning disable` → no suggestions; `:Learning enable` → suggestions resume

It asserts the *interactive behaviour* (a window does / doesn't open). Content
relevance — that a suggestion actually concerns the edit, or an explanation the
selection — is asserted against the raw model response in `tests/run.lua`, which
isn't subject to the float's mid-word line wrapping.

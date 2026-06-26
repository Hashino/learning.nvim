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
- **Window policy** — a suggestion offers learn + dismiss (no direct apply);
  dismissing a suggestion/reminder records toward suppression; an explain-style
  window records nothing.
- **Teach-session state machine** (deterministic) — the pure drill reducer
  escalates the scaffold (analogous → related → solution) on failed submits with
  no failure cap, masters on a correct one, and exits cleanly on give_up/dismiss.
- **Learn-mode drill flow** (deterministic, AI stubbed) — a suggestion's `learn`
  comments the target lines and opens a drill; a wrong submit keeps it active, a
  correct one ends it; give_up restores the buffer.
- **Dismissal suppression** — a feature is suppressed once it reaches
  `dismiss_threshold`.
- **Skill-level gate + knowledge progression** (deterministic) — a language starts
  at `beginner` (the level is inferred, never configured); only tiers at/below the
  unlocked one show; a feature is "known" after `know_threshold` demonstrations,
  and knowing `unlock_threshold` distinct features of a tier promotes to the next
  (capped); promotion comes from demonstrated knowledge only, not from engaging
  with suggestions; progress is per-language and persists across reloads.
- **Cascade gate** (deterministic) — `store.should_teach` pays for stage 2 only
  when the miss is teachable: level is neither `nil` nor `none`, the feature isn't
  suppressed, and its tier is unlocked. All branches are pure. (There is no
  knowledge-based suppression — a feature you know but slip on still gets taught.)
- **Explain, no selection** — `Learning.explain()` with nothing selected notifies
  and opens no window.
- **Stage 1, evaluate (live)** — on freshly generated misses, returns an
  evaluation: a `need_to_learn` with a known tier and an `already_knows` list.
- **Evaluate relevance (live, AI-judged)** — a model (not code) judges whether the
  named `need_to_learn` feature is a relevant improvement for the curated beginner
  misses; a lenient majority must agree. Printed as `INFO  evaluate relevance ...`.
- **Stage 2, teach (live)** — on a clear beginner miss, returns a non-empty prose
  explanation and a well-formed structured edit; whether the prose leaked a fenced
  code block (the dedup rule) is printed as `INFO  teach dedup: ...`.
- **Tier ordering (live)** — curated fixtures grouped by tier (`fixtures.CURATED`)
  evaluate (stage 1) in roughly increasing order: the `beginner` cluster lands
  lowest, `advanced` highest, with `intermediate` in between. Printed as
  `INFO  level classification: ...` every run.
- **Explain, relevance** — explaining a distinctive construct names it (a list
  comprehension → "comprehension").
- **Drill primitives (live)** — `verify` recognizes a clear use of a feature;
  `gen_example` returns a fenced code example (code only).
- **Progress helpers** (deterministic) — `utils.bar` renders a filled/empty bar;
  `store.progress_summary` reports the tier, known features, and how many sit at
  the current tier; `store.languages` lists tracked languages.

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
and exits non-zero on any failure.

Two details keep it reliable on the flaky keyless model:

- It **pre-unlocks every skill tier** for the buffer's language (seeds
  `progress.json` to `advanced`) so the gate never hides a suggestion —
  progression itself is covered deterministically in `run.lua`, so the smoke test
  is free to focus on the *plumbing*.
- Its triggering edits are **genuine beginner misses** (slicing a whole list,
  negative indexing), not idiomatic code — the model correctly returns "nothing
  to teach" (`none`) for already-clean code, so only a real miss opens a window.
  Each window-expecting step is **retried** with a fresh edit to ride out the
  free model's per-call drop rate. The suppression step uses a feature the model
  names consistently (`negative indexing`) so its dismiss counter doesn't split.

In one session it covers:

- startup with no fatal config error
- `:Learning explain` with no selection → notifies
- a trivial reindent → **no** window (edit detection)
- a meaningful edit (a real miss) → a suggestion window opens
- the dismissal cycle: the same feature shows twice, then is suppressed at the threshold
- `:Learning explain` on a real visual selection → an explanation window opens
- `:Learning disable` → no suggestions; `:Learning enable` → suggestions resume

It asserts the *interactive behaviour* (a window does / doesn't open). Content
relevance — that a suggestion actually concerns the edit, or an explanation the
selection — is asserted against the raw model response in `tests/run.lua`, which
isn't subject to the float's mid-word line wrapping.

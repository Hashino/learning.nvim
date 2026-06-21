# learning.nvim — test suite

**When to run.** After a **big change to the main logic** — edit detection, the
prompt / tool-call shape, eagerness gating, or dismissal suppression. Skip it for
docs, config defaults, or small refactors.

## Automated suite (primary)

[`tests/run.lua`](run.lua) drives the real plugin end-to-end against whatever
provider the launching config sets up, prints `PASS`/`FAIL` per check, and exits
non-zero on any failure. **Run it 3 times; it should pass every time** — the value
of repeating is catching model-dependent flicker.

```sh
# fast personal provider (recommended for the repeated runs)
XDG_DATA_HOME=/tmp/learning-test nvim --headless \
  -u custom_nvim_config/init.lua -c "luafile tests/run.lua"

# keyless free Zen (no API key needed)
XDG_DATA_HOME=/tmp/learning-test nvim --headless \
  -u tests/init.lua -c "luafile tests/run.lua"
```

`XDG_DATA_HOME` points dismissal storage at a throwaway dir, so your real
`~/.local/share/nvim/learning.nvim/dismissed.json` is never touched.

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
- **Explain, no selection** — `Learning.explain()` with nothing selected notifies
  and opens no window.
- **Auto-suggestion** — returns a result relevant to the edited lines (the `sum`
  rewrite is taught as `sum`), with importance normalized to `0..1`.
- **Eagerness gate, 3× each at `0.25` and `0.75`** — the show/hide decision is
  **consistent across the three runs**. This is the reliability check at nuanced
  values (see below).
- **Explain, relevance** — explaining a distinctive construct names it (a list
  comprehension → "comprehension").

### Why `0.25` / `0.75`, and why three runs

A suggestion shows when `eagerness > 0` and `importance >= 1 - eagerness`. At `0`
and `1` the gate short-circuits independent of the model, so those only prove the
on/off switch. The interesting region is the middle, where the decision depends on
the importance the model assigns (`0.25` needs `>= 0.75`; `0.75` needs `>= 0.25`).
Running each level three times checks that the model scores **consistently** — the
same edit must land on the same side of the bar every time. If it flickers, the
suspect is the model's importance scoring (prompt/tool), not the gate arithmetic.

### Model reliability

`make_ai_request` retries a few times (`MAX_ATTEMPTS` in `lua/learning/ai.lua`) on
a transient empty/unparseable response, so an occasional dropped tool call doesn't
fail an otherwise-correct run. If a provider still makes the suite flicker a lot,
that provider's tool-calling is unreliable — try the eagerness checks against a
stronger model before suspecting the plugin.

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

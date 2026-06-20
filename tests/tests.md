# learning.nvim — manual test plan

**When to run.** Only run this suite after a **big change to the main logic** —
edit detection, the prompt/tool-call shape, eagerness gating, or dismissal
suppression. It drives a live model and costs time/tokens, so don't run it for
docs, config defaults, or small refactors.

**Run each step 3 times** for reliability (the backend is a live LLM):

- *Deterministic* checks — anything gated purely by config, not model output
  (eagerness `0` vs `1`, the trivial-edit no-trigger checks, dismissal counting) —
  must hold on **all 3** runs.
- *Model-dependent* checks — anything that depends on the importance/feature the
  model assigns (which suggestion shows, the eagerness `0.1` trend) — must hold on
  **at least 2 of 3** runs.

Run the whole plan **in a single Neovim session** per config file.

> **How to run it.** This plan is meant to be driven with
> [tui-use](https://github.com/onesuper/tui-use), which automates a real terminal
> so an agent can launch Neovim, type into a buffer, and read the screen back. The
> step keystrokes and the "wait for the suggestion window, then assert" loop map
> directly onto tui-use's `start` / `type` / `press` / `wait` / `snapshot`
> commands. It can also be run by hand — tui-use just makes each run repeatable.

The plugin has two entry points, tested separately:

1. **Auto-suggestions** — fire automatically after you *edit* a buffer (debounced).
   They teach one language *feature* and may carry a concrete *edit*.
2. **`:Learning explain`** — on-demand explanation of a visual selection.

## Setup

Run with the tracked, keyless dev config — it needs no API key (free OpenCode Zen
models, which support tool calling):

```sh
nvim -u tests/init.lua /tmp/sample.py
```

To run against a different provider, copy `tests/init.lua` and edit the `provider`
block. `tests/init.lua` sets `eagerness = 1` so every suggestion shows, and
`dismiss_threshold = 2`.

`/tmp/sample.py` (recreate if missing):

```python
def greet(name):
    message = "Hello, " + name
    print(message)
    return message


def total(numbers):
    result = 0
    for n in numbers:
        result = result + n
    return result
```

Wait until the session is idle (provider config is validated on `setup`; a bad
provider shows an error notification) before starting.

> **Reset suppression state between full runs.** Dismissals persist to
> `~/.local/share/nvim/learning.nvim/dismissed.json`. Delete it before a run that
> exercises the suppression steps so counts start from zero:
> `rm -f ~/.local/share/nvim/learning.nvim/dismissed.json`.

## How to read results

| Window winbar                                       | Meaning                                  |
| --------------------------------------------------- | ---------------------------------------- |
| `[Learning] <Esc> to dismiss`                       | explanation only, no edit attached       |
| `[Learning] <C-a> to accept \| <Esc> to dismiss`    | suggestion carries an applicable edit    |

(`keys.confirm` is set to `<C-a>` in the dev config so a PTY can send it; the
plugin default is `<S-CR>`, which needs a kitty-keyboard/`modifyOtherKeys`
terminal.)

## Edit-detection invariants (no false triggers)

These are the regression checks for the `vim.text.diff`-based detection. After each
trivial edit, **no suggestion window may open** within ~3s.

- **T1 — re-indent only.** Visually select the body of `greet` and shift it right
  with `>`, then left with `<`. The text is unchanged modulo whitespace → **no
  suggestion**.
- **T2 — blank lines.** Open a few blank lines (`o<Esc>o<Esc>`) and delete them
  (`dd`). Whitespace-only churn → **no suggestion**.
- **T3 — pure deletion.** Delete the `print(message)` line (`dd`). A deletion adds
  no new code → **no suggestion**.
- **T4 — mid-file insertion shift.** Add a new line at the **top** of the file
  (`ggO# a comment<Esc>`). Only the new comment is the change; the suggestion (if
  any) must concern *that line*, never the untouched functions below — confirms the
  old positional-diff "whole file shifted" bug stays fixed.

## Auto-suggestion cases

- **A1 — meaningful edit triggers.** Replace the loop body of `total` with an
  idiomatic form, e.g. change `return result` to `return sum(numbers)` (type it
  out, then leave insert mode). Within a few seconds a `[Learning]` window opens
  teaching a single feature (e.g. `sum`/built-ins). Dismiss with `<Esc>`.
- **A2 — edit suggestion applies.** Make an edit the model is likely to improve
  (e.g. `result = result + n` → keep as-is and let it suggest `+=`). If the window
  shows the `<C-a> to accept` winbar:
  1. **Accept** with `<C-a>`. The window closes and the buffer shows the replacement.
  2. **Verify** the change lands only in the intended region.
  3. **Undo** with `u` before the next step.
- **A3 — in-flight guard.** Type continuously for a few seconds. Only one request
  is in flight at a time; you must never see two suggestion windows stacked.

## Eagerness gating

A suggestion is shown only when `eagerness > 0` **and** its `importance` (set by
the model, 0–1) is at least `1 - eagerness`. So **lower eagerness = fewer
suggestions**, and `eagerness = 0` disables them entirely.

Each level has its own keyless config so you can launch them back-to-back and
compare; all three share `tests/shared.lua`, differing only in eagerness:

| Config                            | eagerness | expected                                       |
| --------------------------------- | --------- | ---------------------------------------------- |
| `tests/init_eagerness_off.lua`    | `0`       | never shows a suggestion                       |
| `tests/init_eagerness_low.lua`    | `0.1`     | shows only high-importance (`>= 0.9`) ones     |
| `tests/init_eagerness_mid.lua`    | `0.5`     | shows medium-and-higher importance (`>= 0.5`)  |
| `tests/init_eagerness_high.lua`   | `1`       | shows every suggestion                         |

The whole point of these is to **assert the behaviour differs as expected** across
the three. Use the **same edit** (the A1 meaningful edit) for all three so the only
variable is eagerness:

```sh
nvim -u tests/init_eagerness_off.lua  /tmp/sample.py   # G1
nvim -u tests/init_eagerness_high.lua /tmp/sample.py   # G2
nvim -u tests/init_eagerness_low.lua  /tmp/sample.py   # G3
```

- **G1 — off (`0`).** Make the A1 edit. **No** window ever opens. *Deterministic:
  must hold all 3 runs.*
- **G2 — high (`1`).** Make the **same** A1 edit. A window **does** open. Contrast
  with G1 on the identical edit proves eagerness changes behaviour. *Deterministic:
  must hold all 3 runs.*
- **G3 — low (`0.1`).** Make a clearly idiomatic improvement (high importance): a
  window opens. Make a minor/borderline edit (low importance): **no** window — it
  was filtered where `high` would have shown it. *Model-dependent trend: must hold
  ≥ 2 of 3 runs.*
- **G4 — mid (`0.5`).** Repeat G3's minor/borderline edit: it should show **more
  often** here than under `low` but **less often** than under `high` — confirming
  the gate scales monotonically between the extremes. *Model-dependent trend: must
  hold ≥ 2 of 3 runs.*

> G1 vs G2 is the reliable, fully-deterministic proof that eagerness gates output;
> G3 demonstrates the in-between scaling, which depends on model-assigned
> importance and so is judged on the trend.

## Dismissal suppression (the core new behavior)

Run after `rm -f ~/.local/share/nvim/learning.nvim/dismissed.json`.

1. **D1** — produce an auto-suggestion about a given feature (e.g. `f-strings`:
   build a string with `+` so the model suggests an f-string). **Dismiss** it with
   `<Esc>` (count → 1).
2. **D2** — make a similar edit that yields the *same* feature again. It still
   shows. **Dismiss** again with `<Esc>` (count → 2, reaching `dismiss_threshold`).
3. **D3** — make a similar edit a third time. The suggestion about that feature is
   now **suppressed** — no window opens for it (the request may still run; the
   result is filtered client-side, and the prompt also asks the model to avoid it).
4. **Verify on disk:** `cat ~/.local/share/nvim/learning.nvim/dismissed.json` shows
   `{"python":{"<feature>":2}}` (the language key is the buffer filetype).
5. **Threshold is configurable:** restart with `dismiss_threshold = 1` in a copy of
   `tests/init.lua`; a single dismissal must now suppress the feature.

> Only an explicit `<Esc>` dismissal counts. **Accepting an edit** (`<C-a>`) or the
> window being replaced by a newer suggestion must **not** increment the count.

## `:Learning explain` cases

- **E1 — explain a selection.** Visually select the `greet` function
  (`ggV2j` or similar) and run `:Learning explain` (or `<leader>le`). A
  dismiss-only `[Learning]` window opens with a markdown explanation of the
  selection. Dismiss with `<Esc>`.
- **E2 — explain is never suppressed.** Even after a feature is suppressed for
  auto-suggestions (steps D1–D3), `:Learning explain` on code using that feature
  still produces an explanation — manual explain is always honored and does not
  record dismissals.

## Pass criteria

- [ ] T1–T4: trivial edits (re-indent, blank lines, deletion) open **no** window;
      a top-of-file insertion never produces a suggestion about untouched code.
- [ ] A1: a meaningful edit opens a `[Learning]` window teaching one feature.
- [ ] A2: accepting an edit suggestion applies it exactly; `u` restores the buffer.
- [ ] A3: never more than one suggestion window at a time.
- [ ] G1/G2: the **same** A1 edit opens no window under `init_eagerness_off.lua`
      and a window under `init_eagerness_high.lua` — behaviour differs by eagerness
      alone (holds all 3 runs).
- [ ] G3: under `init_eagerness_low.lua`, a high-importance edit shows while a minor
      one does not (holds ≥ 2 of 3 runs).
- [ ] D1–D3: the same feature shows up to `dismiss_threshold` dismissals, then is
      suppressed; `dismissed.json` reflects the counts under the filetype key.
- [ ] D5: changing `dismiss_threshold` changes how many dismissals are needed.
- [ ] Accepting an edit does **not** count as a dismissal.
- [ ] E1: `:Learning explain` opens a dismiss-only explanation of the selection.
- [ ] E2: manual explain is never suppressed and records no dismissals.

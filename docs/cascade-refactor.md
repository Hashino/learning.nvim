# Cascade refactor — working notes

Persistent record of the design + decisions + experiment findings for the
two-stage AI cascade refactor of learning.nvim, so nothing is lost to session
compaction. Status as of 2026-06-22, branch `feat/evaluate-cascade`.

## PIVOT (2026-06-22) — `evaluate` cascade + knowledge-driven, inferred levels

Built on branch `feat/evaluate-cascade`. Stage 1 `classify` is replaced by a
single-tool **`evaluate`** returning BOTH `need_to_learn { feature, level }`
(level `none` = nothing to teach) AND `already_knows [{ feature, level }]` (the
features the changed lines demonstrate the user already uses).

- **Levels collapsed to three** — `{ beginner, intermediate, advanced }`,
  intermediate left broad (weak models separate extremes but blur fine grades; the
  old `master` folds into `advanced`).
- **Level is inferred, never configured.** Everyone starts `beginner`; promotion is
  driven purely by demonstrated knowledge, replacing engagement-based
  `record_interaction` (removed). `store.record_knowledge` bumps each demonstrated
  feature's `used` count; a feature is "known" at `used >= know_threshold`; once the
  user knows `unlock_threshold` distinct features of a tier the ceiling rises to the
  next (`L+1`, capped, monotonic). Being taught/drilled is NOT proof — only the
  evaluator seeing unprompted use counts.
- **No knowledge-based suppression.** A feature you know but slip on still gets
  taught (you don't miss what you truly know, so a knowledge gate would mostly fire
  on slips — where a reminder helps — and on hallucinations, which would silently
  and permanently deny a lesson). Only dismissal suppression remains.
- **Gate unchanged** (`should_teach` = level≠none / not dismiss-suppressed /
  is_unlocked); orchestration records knowledge first (so a same-edit miss can clear
  the gate once the ceiling rises), then gates, then teaches.
- **Tests:** deterministic promotion/gate matrix; live `evaluate` shape + tier
  ordering; the non-deterministic output's relevance scored by an **AI judge**
  (`fixtures.judge`, lenient), not brittle code asserts.

This supersedes the engagement-based progression in the 2026-06-21 pivot below.
Next stages (planned): active-recall drill loop, demonstration-routed reminders,
and a progress UI.

## PIVOT (2026-06-21) — skill-level progression replaces numeric eagerness

Being trialled on branch **`feat/skill-stages`**. The numeric `eagerness` knob +
0–10 `importance` rubric (everything below) is **replaced** by a categorical
skill-level model:

- The model classifies each missed feature as `none` / `beginner` /
  `intermediate` / `advanced` / `master` (a `level` enum on the `suggest` tool,
  replacing `importance`). See `lua/learning/config.lua` `Config.LEVELS`.
- The user starts at `beginner`; engaging (accept **or** dismiss) with
  `unlock_threshold` suggestions *at the current top level* unlocks the next.
  Progress is **per-language**, persisted in `progress.json`
  (`lua/learning/store.lua`: `unlocked_level` / `is_unlocked` /
  `record_interaction`).
- `eagerness` is **deprecated** via `vim.deprecate` in `setup` (breaking change,
  noted in README). `utils.meets_eagerness` → `utils.level_index` /
  `normalize_level`.
- Tests rewritten around levels (`tests/run.lua` + `tests/fixtures.lua`
  `CURATED.{beginner,intermediate,advanced,master}`); live checks fire
  concurrently with retry waves; keyless free Zen is the documented default.

**Finding (keyless nemotron-3-ultra-free, 3× stable):** the weak free model
**collapses beginner+intermediate** (both score `beginner`) and is noisy on
advanced/master, but the **extremes separate reliably** (beginner lowest, master
highest, spread ≥ 1 level). So the live test asserts only the robust shape
(easy-extreme-low, hard-extreme-high, clear spread), not exact per-fixture
levels. Crisp 4-way classification needs a stronger model — same lesson as the
importance rubric below. If the branch proves useful, merge to `main` and revise
the cascade's stage-1 `classify` to return `level` instead of `importance`.

The sections below document the SUPERSEDED numeric-importance design and its
experiments; kept for rationale and in case the pivot is reverted.

## Why (the two problems)

1. **Cost the user can't explain.** Every non-trivial debounced edit fires the
   full heavy prompt (prose explanation + structured `edit` + fat schema), then
   most responses are discarded at the eagerness/suppression gate — i.e. we pay
   for generation *before* gating. On free/token-billed providers this quietly
   burns tokens.
2. **Unreliable edit display.** The user sees the model's prose `explanation`;
   whether it contains a usable code snippet is up to the model. The structured
   `edit` (`start`/`final`/`content`) — what `accept` actually applies
   (`lua/learning.lua:79`) — is never shown.

Goal: cheap on the common path, robust for weak/free models, and the corrected
code shown deterministically with no duplicated edit display.

## Design — two-stage cascade (stage 1 = the level detector)

This is the post-pivot cascade: stage 1 is the **skill-level detector** from the
2026-06-21 pivot (it returns a `level`, not a numeric `importance`), and the
client gate is the per-language skill-level/suppression gate — no `eagerness`.

### Stage 1 — classify / level detection (runs on every non-trivial edit; cheap)
- Input: the structured diff from `diff.compute`
  (region-before / region-after, anchored at `diff.start`) — structured input is
  more reliable for weak models than free prose.
- Tool `classify` → `{ feature: string, language: string, level: enum }`, where
  `level` is `none` / `beginner` / `intermediate` / `advanced` / `master`
  (mirrors `config.LEVELS`; `none` = already idiomatic, nothing to teach).
- Small prompt/schema/output: it only names the missed feature and ranks how
  obvious the miss is — it does NOT write the explanation or the edit. `level` is
  coerced through `utils.normalize_level` (unknown degrades to the lowest level,
  never silently `none`).

### Client-side gate (deterministic — no longer trusts the model)
Centralised in `store.should_teach(language, level, feature)`, which is true only
when **all** hold:
- `level` is neither `nil` nor `"none"` (the model found something to teach),
- `store.is_suppressed(language, feature)` is false — suppression of a
  dismissed feature is now enforced **client-side**, so we simply don't fire
  stage 2 for it, instead of trusting the model to honor a suppressed list,
- `store.is_unlocked(language, level)` — the user has progressed to this level.

Only on pass do we pay for stage 2. A gated-out edit costs just the cheap
classify call.

### Stage 2 — teach (runs only past the gate; rare → heavy is affordable)
- Input: same diff + the `feature` stage 1 named ("teach *specifically* X" —
  keeps the two calls aligned).
- Tool `suggest` → `{ explanation (prose), edit { start, final, content } }`.
- `feature` / `language` / `level` are carried over from stage 1 (not re-asked).
- Strict rule: `explanation` must NOT contain the corrected result as a fenced
  code block (we render it). DEDUP PROBE confirmed this rule alone suffices.

Universal two-stage (not capability-gated): accept the extra round-trip latency
on the *rare shown path* in exchange for cheap+robust on the common path. The
in-flight guard (`vim.b.learning_pending`) spans BOTH calls.

### Self-rendered red/green diff (window.lua + learning.lua)
- Source of truth = the structured `edit`. At show-time the buffer still holds
  pre-accept code, so `before = nvim_buf_get_lines(buf, edit.start, edit.final)`,
  `after = edit.content`. Both structural — zero dependence on prose.
- Render a before→after diff at the TOP of the window (old lines red, new green
  via extmarks, askai.nvim-style), prose explanation below. A distinct red/green
  diff makes any stray prose snippet read as redundant, not a confusing twin.
- Deliberate, contained exception to window.lua's "purely mechanical" rule.
- `explain` flow (no edit) renders prose only — unchanged.

## Experiment findings (the important part)

### Dedup ladder — DONE: prompt rule alone suffices
Probe over 4 models (mercury-2 10×, deepseek/big-pickle/nemotron 5× each): under
the strict "no corrected code in `explanation`" rule, **zero leaks** in ~27
successful trials. So: no deterministic strip, no 3rd "clean" AI call. Keep just
the prompt rule.

### Forced `tool_choice` is NOT universal — DONE (committed `a5857db`)
Reasoning/"thinking" models (opencode-free `deepseek-v4-flash`, `big-pickle`;
openrouter `gpt-oss-120b`) reject a forced `tool_choice` with `Thinking mode does
not support this tool_choice`. Fix in `ai.lua` `make_ai_request`/`build_request`:
detect that error and retry the same attempt with `tool_choice="auto"`, relying
on the prompt to compel the call. Verified — those models now work.

### Importance saturation → obviousness rubric — DONE (rubric applied, UNCOMMITTED)
Original problem: every model (incl. **claude-opus-4-8**) parked importance at
~0.8 for almost everything, so eagerness couldn't tell a big deal from a nitpick.
Cross-model calibration (claude/gpt-oss/mercury/nemotron/deepseek/big-pickle) on
the OLD rubric: no separation, ~0.8 across the board.

Two confounds found: (a) the rubric was mediocre; (b) the free fixture generator
mislabeled obvious cases as "subtle" (e.g. `range(len)`).

With **hand-curated clean fixtures + a sharpened rubric** that frames importance
as *how obvious / beginner-level the miss is* (not how clever), separation
appears strongly:

| model | obvious avg | subtle avg | gap (was) |
|---|---|---|---|
| claude-opus-4-8 | 0.90 | 0.37 | 0.53 (0.10) |
| gpt-oss-120b | 0.77 | 0.47 | 0.30 (0.23) |
| mercury-2 | 0.90 | 0.53 | 0.37 (0.13) |

→ **It was the rubric, not model quality.** The sharpened rubric is applied to
`lua/learning/ai.lua` (the `importance` field description), uncommitted, pending
the eagerness-test decision below.

### Eagerness separation is model-noise-dependent — OPEN DECISION
The rubric works, but on the weak default (mercury) the obvious/subtle gap is
**noisy run-to-run (0.10–0.37)**: obvious is stable ~0.85, but subtle fixtures
`dict.keys()` and `len(x)==0` swing 0.5–0.8 (only `sum([...])`-brackets is
reliably low). Reliable separation on capable models (Claude gap 0.53); noisy on
weak ones. So a hard per-run separation assertion flakes on mercury.

**Open:** how the live eagerness-separation check should behave —
(a) informational (print gap, don't fail; deterministic gate math stays the hard
guarantee); (b) denoise with ~3 reps/fixture + lenient threshold (~+18 calls/run);
(c) hard-assert obvious-scores-high only, report subtle gap as info.
*(User is clarifying the question as of this writing.)*

### gpt-oss-120b works → README recommendation — DONE (committed `15eb7b9`)
With the `tool_choice` fallback, `openai/gpt-oss-120b:free` (OpenRouter, free) is
a capable usable provider; README now recommends it.

## Test approach
- `tests/run.lua` — deterministic checks + live checks against the launch
  provider; exits non-zero on any failure.
- `tests/fixtures.lua` — **AI-generated fixtures**: a random keyless free Zen
  model invents fresh code each run (askai.nvim "invent every run" spirit).
  Categories: `obvious` (generated reliably) and `subtle` (generator unreliable —
  tends to emit obvious cases). `Fixtures.CURATED` holds a hand-curated clean
  obvious/subtle set for the separation test. Falls back to a template on
  generation failure. Generation is decoupled from the plugin-under-test provider
  so the suite needs no API key.
- `tests/smoke.sh` — single-session tui-use end-to-end (the real
  keystroke→autocmd→debounce→window→keymap path).

## Commits landed (this effort)
- `56e1139` test: broaden deterministic coverage; factor out eagerness gate + expose ai parsers
- `88b28ac` test: generate live fixtures via free Zen models each run
- `a5857db` feat(ai): fall back to tool_choice=auto when a provider rejects forced
- `15eb7b9` docs(README): recommend free gpt-oss-120b provider

Uncommitted (pending eagerness decision): the sharpened importance rubric
(`ai.lua`), the category generator + curated set (`fixtures.lua`), the rewired
live section (`run.lua`).

## Remaining work — STATUS

The skill-level pivot (1) is DONE and merged to `main` (`0.2.1`). The cascade
split itself is being built on branch `feat/cascade`:

1. ~~Resolve the eagerness-check behavior~~ → SUPERSEDED by the skill-level
   pivot; live tests assert level ordering, deterministic tests assert the gate.
2. Stage split: `AI.classify` (level detector) + `AI.teach` replacing
   `AI.suggestion`; structured stage-1 input; strict no-snippet rule in stage 2.
3. `send_suggestion` orchestration: classify → client gate
   (`store.should_teach` = level≠none/`is_suppressed`/`is_unlocked`) → teach →
   `Learning.show`; the `learning_pending` guard spans both calls.
4. Self-rendered red/green diff in `window.lua`: `Learning.show` reads the
   pre-accept lines from the buffer (`before`) and the edit `content` (`after`)
   and passes them to `window.show({ diff = { before, after } })`, rendered as
   red/green lines (extmark `line_hl_group`) above the prose.
5. Tests alongside each piece: deterministic `store.should_teach` gate matrix;
   live classify (level) + teach (edit shape, dedup) + explain; smoke unchanged.
6. Docs: update `tests/tests.md` (cascade + gate) and `README` (how-it-works).

## Constraints / gotchas
- `custom_nvim_config/` and the user's `~/.config/nvim/.../ai.lua` hold real API
  keys — never commit/print them. Test scripts read keys at runtime.
- `provider.headers = { Authorization = "" }` is the DEV-ONLY keyless escape hatch
  (free Zen). Tests isolate state with `XDG_DATA_HOME=/tmp/...`.
- Style/workflow per the `hash-nvim-plugin-dev` skill: setup-first, doing.nvim as
  ground truth, commit after every change, squash to Conventional Commits before
  a manual push.

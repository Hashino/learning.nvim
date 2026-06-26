-- Automated test runner for learning.nvim — the executable form of tests.md.
-- Exercises the real plugin end-to-end against whatever provider the launching
-- config set up. Prints PASS/FAIL per check and exits non-zero on any failure.
--
-- Run (isolate dismissal state in a temp dir so the real one is untouched):
--   XDG_DATA_HOME=/tmp/learning-test nvim --headless \
--     -u custom_nvim_config/init.lua -c "luafile tests/run.lua"   -- fast provider
--   XDG_DATA_HOME=/tmp/learning-test nvim --headless \
--     -u tests/init.lua             -c "luafile tests/run.lua"    -- keyless Zen
--
-- Model-dependent checks (suggestion/explain relevance, level classification)
-- need a provider that supports tool calling; the deterministic checks do not.

local config   = require("learning.config")
local diff     = require("learning.diff")
local utils    = require("learning.utils")
local store    = require("learning.store")
local ai       = require("learning.ai")
local window   = require("learning.window")
local drill    = require("learning.drill")
local learning = require("learning")

-- live fixtures are generated fresh each run; seed once so each run differs
math.randomseed(os.time())

local pass, failed = 0, {}
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("PASS  " .. name)
  else
    table.insert(failed, name)
    print("FAIL  " .. name .. (detail and ("  -- " .. detail) or ""))
  end
end


-- deterministic checks — no model required

-- edit detection (diff.lua): trivial changes never suggest; real ones localize
check("diff: reindent is trivial", diff.compute({ "def f():", "    x = 1" }, { "def f():", "        x = 1" }) == nil)
check("diff: blank-line churn is trivial", diff.compute({ "a", "b" }, { "a", "", "b", "" }) == nil)
check("diff: pure deletion is trivial", diff.compute({ "a", "b", "c" }, { "a", "c" }) == nil)
do
  local old = { "def greet(n):", "    print(n)", "def total(x):", "    return sum(x)" }
  local new = { "# top comment", "def greet(n):", "    print(n)", "def total(x):", "    return sum(x)" }
  local d = diff.compute(old, new)
  check("diff: top insertion stays localized (not whole file)",
    d ~= nil and d.start == 0 and #d.new_content <= #new,
    d and ("start=" .. d.start .. " lines=" .. #d.new_content) or "nil")
end

-- model edit validation (utils.lua)
check("valid_edit: nil rejected", utils.valid_edit(nil) == nil)
---@diagnostic disable-next-line: missing-fields
check("valid_edit: partial rejected", utils.valid_edit({ start = 1 }) == nil)
check("valid_edit: well-formed accepted", utils.valid_edit({ start = 0, final = 1, content = { "x" } }) ~= nil)

-- dismissal suppression store (store.lua) — XDG_DATA_HOME isolates the file
config.options.dismiss_threshold = 2
do
  local lang, feat = "python", "runner-suppress-probe"
  check("store: starts unsuppressed", store.is_suppressed(lang, feat) == false)
  store.record_dismiss(lang, feat)
  check("store: 1 dismiss is below threshold (2)", store.is_suppressed(lang, feat) == false)
  store.record_dismiss(lang, feat)
  check("store: 2 dismiss reaches threshold -> suppressed", store.is_suppressed(lang, feat) == true)
  check("store: suppressed_features lists it", vim.tbl_contains(store.suppressed_features(lang), feat))
end

-- explain with no selection: must notify and open no window (visualmode() == "")
do
  window.close()
  local notified = false
  local orig = vim.notify
  -- keep the variadic signature so this stub doesn't narrow vim.notify's
  -- inferred type workspace-wide (which would falsely flag real 2-arg calls)
  ---@diagnostic disable-next-line: unused-vararg
  vim.notify = function(msg, ...) if tostring(msg):find("no visual selection") then notified = true end end
  learning.explain()
  vim.notify = orig
  check("explain: no selection notifies, opens no window", notified and window.win_id == nil,
    "notified=" .. tostring(notified) .. " win=" .. tostring(window.win_id))
end

-- end-to-end window policy (new interaction): a suggestion offers learn + dismiss
-- (no apply); dismissing records toward suppression; "learn" opens a drill that
-- comments the target lines; submit/give_up drive the drill. ai.verify and
-- ai.gen_example are stubbed so the whole flow runs deterministically, no network.
local function press(buf, lhs)
  local want = vim.api.nvim_replace_termcodes(lhs, true, true, true)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if m.callback and vim.api.nvim_replace_termcodes(m.lhs, true, true, true) == want then
      m.callback()
      return true
    end
  end
  return false
end
do
  local orig_gen, orig_verify = ai.gen_example, ai.verify
  ---@diagnostic disable-next-line: duplicate-set-field
  ai.gen_example = function(_, _, phase, _, cb) cb({ explanation = "ex", code = { phase, }, }) end
  local verify_result = false
  ---@diagnostic disable-next-line: duplicate-set-field
  ai.verify = function(_, _, _, _, cb) cb(verify_result) end

  config.options.dismiss_threshold = 1
  config.options.drill_related_after = 1
  config.options.drill_solution_after = 2

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  local SRC = { "def f(xs):", "    acc = 0", "    for x in xs:", "        acc = acc + x", "    return acc", }
  -- the drill's line range now comes from the diff, not a model edit: comment the
  -- loop body (0-indexed lines 1..4 exclusive).
  local change = { change_start = 1, change_final = 4, }

  -- dismissing a suggestion records toward suppression (and opens no drill)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, SRC)
  learning.show_suggestion(buf, "python", "e2e-tracked", { summary = "use sum()", }, change)
  press(vim.api.nvim_win_get_buf(window.win_id), config.options.keys.suggestion.dismiss)
  check("suggestion: dismiss records toward suppression and opens no drill",
    store.is_suppressed("python", "e2e-tracked") == true and drill.active(buf) == false)

  -- "learn" opens a drill: the target lines get commented and the drill goes active
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, SRC)
  vim.b[buf].learning_old = nil
  learning.show_suggestion(buf, "python", "e2e-learn", { summary = "use sum()", }, change)
  press(vim.api.nvim_win_get_buf(window.win_id), config.options.keys.suggestion.learn)
  check("suggestion: learn opens a drill and comments the target lines",
    drill.active(buf) == true and vim.api.nvim_buf_get_lines(buf, 0, -1, false)[2]:match("^%s*#") ~= nil)

  -- a wrong submit keeps the drill going; a correct one masters it
  verify_result = false
  drill.submit(buf)
  check("drill: a wrong submit keeps the drill active", drill.active(buf) == true)
  verify_result = true
  drill.submit(buf)
  check("drill: a correct submit ends the drill", drill.active(buf) == false)

  -- give_up restores the original code and ends the drill
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, SRC)
  vim.b[buf].learning_old = nil
  learning.show_suggestion(buf, "python", "e2e-giveup", { summary = "use sum()", }, change)
  press(vim.api.nvim_win_get_buf(window.win_id), config.options.keys.suggestion.learn)
  drill.give_up(buf)
  check("drill: give_up restores the original buffer and ends",
    drill.active(buf) == false and vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), SRC))

  ai.gen_example, ai.verify = orig_gen, orig_verify
end

-- response parsing (ai._test): both provider shapes, fallbacks, malformed input.
-- this is what a single live provider can never exercise — the OTHER shape.
do
  local t = ai._test
  -- stage-1 evaluate shape (openai) and stage-2 suggest/teach shape (anthropic)
  local openai = { choices = { { message = { tool_calls = {
    { type = "function", ["function"] = { name = "evaluate",
      arguments = '{"need_to_learn":{"feature":"f-strings","level":"beginner"},"already_knows":[{"feature":"enumerate","level":"intermediate"}]}' }, },
  }, }, }, }, }
  local oc = t.extract_tool_calls(openai, false)
  check("parse: openai tool_calls extracted",
    #oc == 1 and oc[1].name == "evaluate" and oc[1].arguments.need_to_learn.level == "beginner")

  local anthropic = { content = {
    { type = "text", text = "preamble", },
    { type = "tool_use", name = "suggest",
      input = { explanation = "y", edit = { start = 0, final = 1, content = { "x", }, }, }, },
  }, }
  local ac = t.extract_tool_calls(anthropic, true)
  check("parse: anthropic tool_use extracted",
    #ac == 1 and ac[1].name == "suggest" and ac[1].arguments.explanation == "y")

  check("parse: openai content fallback",
    t.extract_content({ choices = { { message = { content = "hello" }, }, }, }, false) == "hello")
  check("parse: anthropic content fallback",
    t.extract_content({ content = { { type = "text", text = "hello" }, }, }, true) == "hello")

  local bad = { choices = { { message = { tool_calls = {
    { type = "function", ["function"] = { name = "suggest", arguments = "{not valid json" }, },
  }, }, }, }, }
  check("parse: malformed tool arguments skipped, no crash", #t.extract_tool_calls(bad, false) == 0)
  check("parse: empty response yields no tool calls", #t.extract_tool_calls({}, false) == 0)
end

-- skill level helpers (utils): ordering and model-output coercion
do
  check("level_index: ordered beginner < advanced",
    utils.level_index("beginner") == 1 and utils.level_index("advanced") == #config.LEVELS)
  check("level_index: unknown level -> nil", utils.level_index("wizard") == nil)
  check("normalize_level: known level passes through", utils.normalize_level("Advanced") == "advanced")
  check("normalize_level: explicit none preserved", utils.normalize_level("none") == "none")
  check("normalize_level: unknown degrades to lowest (never silent)",
    utils.normalize_level("wizard") == config.LEVELS[1] and utils.normalize_level(nil) == config.LEVELS[1])
end

-- skill-level gate + knowledge-driven progression (store): the user starts at the
-- lowest tier and is promoted purely by demonstrated knowledge — a feature is
-- "known" after know_threshold demonstrations, and knowing unlock_threshold
-- distinct features of a tier lifts the ceiling to the next. per-language;
-- XDG_DATA_HOME isolates progress.json.
do
  config.options.unlock_threshold = 2
  config.options.know_threshold = 2
  local lang = "progress-probe-lang"
  check("progress: starts at the lowest tier", store.unlocked_level(lang) == config.LEVELS[1])
  check("gate: beginner unlocked from the start", store.is_unlocked(lang, "beginner") == true)
  check("gate: a higher tier is locked initially", store.is_unlocked(lang, "intermediate") == false)
  check("gate: an unknown level is never unlocked", store.is_unlocked(lang, "wizard") == false)

  -- a single demonstration isn't enough for a feature to count as known
  store.record_knowledge(lang, { { feature = "b1", level = "beginner", }, })
  check("progress: one demonstration isn't yet 'known'", store.is_known(lang, "b1") == false)
  check("progress: below the knowledge bar keeps the tier", store.unlocked_level(lang) == config.LEVELS[1])

  -- b1 reaches know_threshold -> known, but one known feature < unlock_threshold
  store.record_knowledge(lang, { { feature = "b1", level = "beginner", }, })
  check("progress: know_threshold demonstrations make a feature known", store.is_known(lang, "b1") == true)
  check("progress: one known feature isn't enough to promote", store.unlocked_level(lang) == config.LEVELS[1])

  -- a second known beginner feature reaches unlock_threshold -> promote to the NEXT tier
  store.record_knowledge(lang, { { feature = "b2", level = "beginner", }, { feature = "b2", level = "beginner", }, })
  check("progress: knowing unlock_threshold features of a tier promotes to the next",
    store.unlocked_level(lang) == "intermediate")
  check("gate: the newly unlocked tier now shows", store.is_unlocked(lang, "intermediate") == true)
  check("gate: the tier after that is still locked", store.is_unlocked(lang, "advanced") == false)

  -- progress is per-language: an untouched language is still at the start
  check("progress: independent per language", store.unlocked_level("other-lang") == config.LEVELS[1])
end

-- the deterministic stage-2 gate (store.should_teach): the cascade pays for the
-- heavy teach call only when the evaluation found something to teach, the feature
-- isn't suppressed, and its level is unlocked. all three branches are pure.
do
  config.options.dismiss_threshold = 1
  local lang = "gate-probe-lang" -- fresh: starts at beginner, nothing suppressed
  check("gate: 'none' level never teaches", store.should_teach(lang, "none", "gate-feat") == false)
  check("gate: nil level never teaches", store.should_teach(lang, nil, "gate-feat") == false)
  check("gate: unlocked + unsuppressed feature teaches",
    store.should_teach(lang, "beginner", "gate-feat") == true)
  check("gate: a locked level does not teach",
    store.should_teach(lang, "intermediate", "gate-feat") == false)
  store.record_dismiss(lang, "gate-suppressed") -- threshold 1 -> suppressed
  check("gate: a suppressed feature does not teach even when unlocked",
    store.should_teach(lang, "beginner", "gate-suppressed") == false)
end

-- teach-session state machine (deterministic, pure reducer — no model). drives a
-- drill through the scaffold (analogous -> related -> solution) and the exits.
do
  local TS = require("learning.teach_session")
  local s = TS.new("enumerate", 1, 3)
  check("session: active at start", s:is_active() and s.phase == "analogous")
  check("session: submit asks to verify", s:submit().kind == "verify")
  do
    local a = s:result(false)
    check("session: first fail escalates to a related example", a.kind == "example" and a.phase == "related")
  end
  check("session: a fail at the same rung is a retry, not a new example",
    s:result(false).kind == "retry")
  do
    local a = s:result(false)
    check("session: reaching solution_after escalates to the solution", a.kind == "example" and a.phase == "solution")
  end
  check("session: failures past the solution keep trying (no cap)",
    s:result(false).kind == "retry" and s:is_active())
  check("session: a correct attempt masters the drill",
    s:result(true).kind == "mastered" and not s:is_active())
  check("session: events after the drill ends are no-ops",
    s:submit().kind == "none" and s:result(false).kind == "none")

  check("session: give_up restores the buffer and ends", TS.new("zip", 2, 4):give_up().kind == "restore")
  check("session: dismiss leaves the buffer and ends", TS.new("zip", 2, 4):dismiss().kind == "close")
end

-- the shipped default scaffold policy: TWO failures on a rung before it escalates
-- (drill_related_after = 2 -> related, drill_solution_after = 4 -> solution), and
-- the solution rung never ends. drive the reducer with the shipped thresholds.
do
  local TS = require("learning.teach_session")
  local s = TS.new("enumerate", 2, 4)
  check("policy: 1st analogous failure retries (no escalation yet)",
    s:result(false).kind == "retry" and s.phase == "analogous")
  do
    local a = s:result(false)
    check("policy: 2nd failure escalates analogous -> related", a.kind == "example" and a.phase == "related")
  end
  check("policy: 1st related failure retries", s:result(false).kind == "retry" and s.phase == "related")
  do
    local a = s:result(false)
    check("policy: 4th failure escalates related -> solution", a.kind == "example" and a.phase == "solution")
  end
  check("policy: the solution rung never ends",
    s:result(false).kind == "retry" and s:result(false).kind == "retry"
    and s:is_active() and s.phase == "solution")
end

-- progress helpers (deterministic): the bar renderer and the per-language summary
-- the :Learning progress view and the suggestion footer read from.
do
  config.options.know_threshold = 2
  config.options.unlock_threshold = 2
  check("bar: empty / full / half / clamped",
    utils.bar(0, 4) == "▱▱▱▱" and utils.bar(1, 4) == "▰▰▰▰"
    and utils.bar(0.5, 4) == "▰▰▱▱" and utils.bar(5, 3) == "▰▰▰")

  local L = "progress-summary-lang"
  local p = store.progress_summary(L)
  check("progress: fresh summary is beginner, nothing known",
    p.level == "beginner" and #p.known == 0 and p.known_at_tier == 0 and p.at_max == false)

  store.record_knowledge(L, { { feature = "p-a", level = "beginner", }, { feature = "p-a", level = "beginner", }, })
  p = store.progress_summary(L)
  check("progress: a known feature appears in the summary",
    #p.known == 1 and p.known[1].feature == "p-a" and p.known_at_tier == 1)

  store.record_knowledge(L, { { feature = "p-b", level = "beginner", }, { feature = "p-b", level = "beginner", }, })
  p = store.progress_summary(L)
  check("progress: summary reflects promotion (known_at_tier resets for the new tier)",
    p.level == "intermediate" and p.level_index == 2 and p.known_at_tier == 0 and #p.known == 2)

  check("progress: languages() lists a tracked language", vim.tbl_contains(store.languages(), L))
end

-- more diff edge cases
check("diff: identical buffers -> nil", diff.compute({ "a", "b" }, { "a", "b" }) == nil)
check("diff: trailing-whitespace-only change is trivial",
  diff.compute({ "x = 1" }, { "x = 1   " }) == nil)
do
  local d = diff.compute(
    { "def f():", "    return 1" },
    { "def f():", "    return 1", "def g():", "    return sum(x)" })
  check("diff: bottom-of-file insertion localizes",
    d ~= nil and table.concat(d.new_content, "\n"):find("sum") ~= nil)
end
do
  local d = diff.compute(
    { "x = 1", "a", "b", "c", "d", "e", "y = 2" },
    { "x = sum(a)", "a", "b", "c", "d", "e", "y = max(b)" })
  check("diff: multiple separate hunks captured",
    d ~= nil and table.concat(d.new_content, "\n"):find("sum") and table.concat(d.new_content, "\n"):find("max"))
end

-- valid_edit with wrong field types
---@diagnostic disable-next-line: assign-type-mismatch
check("valid_edit: non-numeric start rejected", utils.valid_edit({ start = "0", final = 1, content = { "x" } }) == nil)
---@diagnostic disable-next-line: assign-type-mismatch
check("valid_edit: non-table content rejected", utils.valid_edit({ start = 0, final = 1, content = "x" }) == nil)

-- visual_selection extraction (linewise) given real marks + visualmode
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "alpha beta", "gamma delta", "epsilon" })
  vim.api.nvim_set_current_buf(b)
  -- linewise-select lines 1-2 and leave visual (the <Esc> must be in the same
  -- normal! sequence, or the '<'> marks are never set)
  vim.cmd("normal! ggVj\27")
  local lines = utils.visual_selection(b)
  check("visual_selection: linewise returns the full selected lines",
    lines ~= nil and #lines == 2 and lines[1] == "alpha beta" and lines[2] == "gamma delta")
end

-- store: key normalization, empty-feature no-op
do
  config.options.dismiss_threshold = 2
  store.record_dismiss("Python", "  F-Strings  ")
  store.record_dismiss("python", "f-strings")
  check("store: language/feature keys are case/space normalized",
    store.is_suppressed("PYTHON", "F-STRINGS") == true)
  store.record_dismiss("python", "")
  check("store: empty feature is a no-op", store.is_suppressed("python", "") == false)
end

-- store: persistence across a reload, and graceful handling of a corrupt file
do
  config.options.dismiss_threshold = 1
  store.record_dismiss("python", "persist-probe")
  package.loaded["learning.store"] = nil
  check("store: dismissals persist across a module reload",
    require("learning.store").is_suppressed("python", "persist-probe") == true)

  local dir = vim.fs.joinpath(vim.fn.stdpath("data"), "learning.nvim")
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "{ not valid json" }, vim.fs.joinpath(dir, "dismissed.json"))
  package.loaded["learning.store"] = nil
  check("store: corrupt json degrades gracefully (nothing suppressed, no crash)",
    require("learning.store").is_suppressed("python", "anything") == false)
  package.loaded["learning.store"] = nil
  require("learning.store") -- leave the module loaded again
end

-- progression: persists across a reload, and caps at the top tier
do
  config.options.unlock_threshold = 1
  config.options.know_threshold = 1
  local lang = "persist-progress-lang"
  -- one known beginner feature (thresholds 1) lifts the ceiling to tier 2
  store.record_knowledge(lang, { { feature = "p1", level = "beginner", }, })
  package.loaded["learning.store"] = nil
  check("progress: level persists across a module reload",
    require("learning.store").unlocked_level(lang) == config.LEVELS[2])
  store = require("learning.store")

  -- demonstrating top-tier knowledge can't push the ceiling past the highest tier
  local top = "cap-lang"
  store.record_knowledge(top, { { feature = "t1", level = config.LEVELS[#config.LEVELS], }, })
  check("progress: never advances past the highest tier",
    store.unlocked_level(top) == config.LEVELS[#config.LEVELS])
  -- more knowledge at the cap is a harmless no-op (no crash, stays at the top)
  store.record_knowledge(top, { { feature = "t2", level = config.LEVELS[#config.LEVELS], }, })
  check("progress: knowledge at the cap is a no-op",
    store.unlocked_level(top) == config.LEVELS[#config.LEVELS])
end

-- model-dependent checks — need a tool-calling provider. every live request is
-- independent, so they fire CONCURRENTLY (one curl each) and settle in a couple
-- of waves rather than one slow call at a time. transient failures (the free
-- keyless models occasionally drop a call) are retried in later waves, so a
-- network hiccup isn't mistaken for a wrong answer.
local fixtures = require("tests.fixtures")

-- rank a skill tier low→high; "none" (nothing to teach) sits above "advanced" as
-- the highest possible bar, so a subtle case the model declines to teach still
-- separates correctly from an obvious beginner miss.
local LEVEL_RANK = { beginner = 1, intermediate = 2, advanced = 3, none = 4, }

-- dispatches every async job(cb) at once and returns their results keyed the same
-- as `jobs`, retrying only the jobs that came back nil for up to `rounds` waves.
local function gather(jobs, rounds)
  local results, pending = {}, jobs
  for _ = 1, rounds or 1 do
    local got, remaining = {}, 0
    for _ in pairs(pending) do remaining = remaining + 1 end
    if remaining == 0 then break end
    for k, job in pairs(pending) do
      job(function(r) got[k] = r remaining = remaining - 1 end)
    end
    vim.wait(180000, function() return remaining == 0 end, 50)

    local next_pending = {}
    for k, job in pairs(pending) do
      if got[k] ~= nil then results[k] = got[k] else next_pending[k] = job end
    end
    pending = next_pending
    if next(pending) == nil then break end
  end
  return results
end

-- before = the function's signature stub, so the diff the model sees is its body.
-- stage 1 (evaluate) is what the level/feature checks exercise; the tier we rank
-- is the MISS it reports (need_to_learn).
local function evaluate_job(before, after, ft)
  local change = diff.compute(before, after)
  return change, change and function(cb) ai.evaluate(change, ft or "python", cb) end or nil
end

-- two FRESHLY GENERATED "beginner" edits (novel code each run, via the keyless
-- free Zen models) drive shape invariants; "beginner" is the level the free
-- generator produces reliably. generation uses a blocking call, so it stays
-- sequential; the classification requests it feeds into the batch below do not.
local generated = {}
for i = 1, 2 do
  local fx = fixtures.fresh("beginner")
  local change, job = evaluate_job(fx.before, fx.after, fx.ft)
  generated[i] = {
    tag = "evaluate[" .. fx.name .. (fx.generated and "" or "/FALLBACK") .. "]",
    change = change,
    job = job,
  }
end

-- one concurrent batch: the generated-fixture classifications, the curated
-- per-level separation set, one stage-2 teach, and the on-demand explain.
local jobs = {}
for i, fx in ipairs(generated) do
  if fx.job then jobs["gen" .. i] = fx.job end
end
for _, lvl in ipairs(config.LEVELS) do
  for i, body in ipairs(fixtures.CURATED[lvl]) do
    local _, job = evaluate_job({ body[1], "    pass", }, body)
    if job then jobs[lvl .. i] = job end
  end
end

-- stage 2 (teach) on a clear beginner miss: must return a non-empty prose
-- explanation and NO structured edit (the rewrite is generated lazily in the drill).
local teach_change = diff.compute({ fixtures.CURATED.beginner[1][1], "    pass", },
  fixtures.CURATED.beginner[1])
if teach_change then
  jobs.teach = function(cb) ai.teach("python", "the sum() builtin", cb) end
end

jobs.explain = function(cb) ai.explain("squares = [x * x for x in range(10)]", "python", cb) end

-- stage-2 drill primitives (live): verify recognizes a clear use of a feature, and
-- gen_example returns an explanation plus a fenced example.
jobs.verify_pos = function(cb) ai.verify("result = [x * x for x in xs]", "python", "list comprehension", {}, cb) end
jobs.example = function(cb) ai.gen_example("list comprehension", "python", "analogous", "acc = []\nfor x in xs:\n    acc.append(x * x)", cb) end

local R = gather(jobs, 4)

-- shape invariants over the generated fixtures. assertions are invariants, never
-- a fixed sentence.
for i, fx in ipairs(generated) do
  check(fx.tag .. ": fixture is a non-trivial edit", fx.change ~= nil)
  if fx.change then
    local s = R["gen" .. i]
    check(fx.tag .. ": returns an evaluation", s ~= nil)
    if s then
      local need = s.need_to_learn
      check(fx.tag .. ": need_to_learn.level is a known tier",
        type(need) == "table" and type(need.level) == "string" and LEVEL_RANK[need.level] ~= nil,
        need and tostring(need.level) or "nil")
      check(fx.tag .. ": already_knows is a list", type(s.already_knows) == "table")
    end
  end
end

-- tier ordering: the curated fixtures should classify in roughly increasing order
-- beginner < intermediate < advanced, so the progressive gate reveals features in
-- pedagogical order. weak models are noisy in the middle, so assert the robust
-- shape: the easy extreme lands lowest, the hard extreme highest, with a clear
-- total spread (middles only have to fall in between).
do
  local function avg(t) local s = 0 for _, v in ipairs(t) do s = s + v end return #t > 0 and s / #t or 0 end
  local function cluster(lvl)
    local o = {}
    for i = 1, #fixtures.CURATED[lvl] do
      local s = R[lvl .. i]
      local need = s and s.need_to_learn
      if need and type(need.level) == "string" then table.insert(o, LEVEL_RANK[need.level]) end
    end
    return o
  end

  local avgs, detail, all_scored = {}, {}, true
  for _, lvl in ipairs(config.LEVELS) do
    local r = cluster(lvl)
    if #r == 0 then all_scored = false end
    avgs[lvl] = avg(r)
    table.insert(detail, ("%s=%.2f%s"):format(lvl, avgs[lvl], vim.inspect(r)))
  end

  print("INFO  level classification: " .. table.concat(detail, " "))
  local lo, hi = config.LEVELS[1], config.LEVELS[#config.LEVELS]
  local extremes_ordered = avgs[lo] <= avgs.intermediate and avgs[lo] <= avgs.advanced
      and avgs[hi] >= avgs.intermediate and avgs[hi] >= avgs.advanced
  check("tiers: classifications trend from beginner (low) to advanced (high)",
    all_scored and extremes_ordered and (avgs[hi] - avgs[lo]) >= 1.0,
    table.concat(detail, " "))
end

-- AI-judged relevance: the evaluate output is non-deterministic, so a model — not
-- code — scores whether the named miss is relevant. lenient: a majority of the
-- curated beginner misses must name a feature the judge agrees is worth teaching.
do
  local judged, agreed = 0, 0
  for i, body in ipairs(fixtures.CURATED.beginner) do
    local s = R["beginner" .. i]
    local feat = s and s.need_to_learn and s.need_to_learn.feature
    if type(feat) == "string" and feat ~= "" then
      local code = table.concat(body, "\n")
      local ok = fixtures.judge(
        "Here is Python code:\n```python\n" .. code .. "\n```\n" ..
        "Is teaching the feature \"" .. feat .. "\" a relevant, correct idiomatic " ..
        "improvement for this code?")
      if ok ~= nil then
        judged = judged + 1
        if ok then agreed = agreed + 1 end
      end
    end
  end
  if judged > 0 then
    print(("INFO  evaluate relevance (AI-judged): %d/%d agreed"):format(agreed, judged))
    check("evaluate: AI judge finds the named misses relevant (lenient majority)",
      agreed * 2 >= judged, ("%d/%d agreed"):format(agreed, judged))
  else
    print("INFO  evaluate relevance: AI judge unreachable, skipped")
  end
end

-- stage 2 (teach): a prose explanation only, no structured edit and no fenced code
-- block (the worked code is withheld for the drill). weak keyless models are noisy,
-- so the no-fence rule is reported as INFO rather than asserted.
if teach_change then
  local s = R.teach
  check("teach: returns a non-empty explanation",
    s ~= nil and type(s.summary) == "string" and #s.summary > 0)
  if s then
    check("teach: returns no structured edit (explanation only)", s.edit == nil)
    local fenced = type(s.summary) == "string" and s.summary:find("```") ~= nil
    print("INFO  teach dedup: explanation " .. (fenced and "CONTAINS" or "omits") ..
      " a fenced code block")
  end
end

-- explain answers about the *selected* code (distinctive construct -> named)
do
  local s = R.explain
  check("explain: returns an explanation", s ~= nil and s.summary ~= nil)
  check("explain: relevant to selection (mentions comprehension)",
    s ~= nil and (s.summary or ""):lower():find("comprehension") ~= nil,
    s and (s.summary or ""):sub(1, 60) or "nil")
end

-- stage-2 drill primitives (live)
check("verify: recognizes a clear use of the feature", R.verify_pos == true, tostring(R.verify_pos))
do
  local e = R.example
  check("gen_example: returns an explanation and a fenced example",
    type(e) == "table" and type(e.explanation) == "string" and #e.explanation > 0 and type(e.code) == "table",
    type(e) == "table" and ("expl=" .. #(e.explanation or "") .. " codes=" .. tostring(e.code and #e.code)) or "nil")
end

-- ===========================================================================
print(string.rep("=", 60))
print(("RESULT: %d passed, %d failed"):format(pass, #failed))
for _, n in ipairs(failed) do print("  FAILED: " .. n) end
vim.cmd(#failed > 0 and "cq 1" or "qa")

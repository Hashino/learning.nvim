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

-- end-to-end window policy: accept applies the edit; dismiss records; neither
-- an untracked dismiss nor an explain dismiss records.
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
  config.options.dismiss_threshold = 1
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a = a + 1" })
  learning.show(buf, { summary = "use +=", edit = { start = 0, final = 1, content = { "a += 1" } } })
  local ok_accept = press(vim.api.nvim_win_get_buf(window.win_id), config.options.keys.confirm)
  check("accept: applies the edit to the buffer",
    ok_accept and vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "a += 1")

  learning.show(buf, { summary = "x", language = "python", feature = "e2e-tracked", track_dismiss = true })
  press(vim.api.nvim_win_get_buf(window.win_id), config.options.keys.dismiss)
  check("dismiss: tracked dismiss records toward suppression (threshold 1)",
    store.is_suppressed("python", "e2e-tracked") == true)

  learning.show(buf, { summary = "x", language = "python", feature = "e2e-untracked" })
  press(vim.api.nvim_win_get_buf(window.win_id), config.options.keys.dismiss)
  check("dismiss: untracked dismiss does not record",
    store.is_suppressed("python", "e2e-untracked") == false)

  learning.show(buf, { summary = "explained", language = "python", feature = "e2e-explain" })
  press(vim.api.nvim_win_get_buf(window.win_id), config.options.keys.dismiss)
  check("explain-style window (no track_dismiss) does not record",
    store.is_suppressed("python", "e2e-explain") == false)
end

-- response parsing (ai._test): both provider shapes, fallbacks, malformed input.
-- this is what a single live provider can never exercise — the OTHER shape.
do
  local t = ai._test
  local openai = { choices = { { message = { tool_calls = {
    { type = "function", ["function"] = { name = "suggest", arguments = '{"explanation":"x","level":"beginner"}' }, },
  }, }, }, }, }
  local oc = t.extract_tool_calls(openai, false)
  check("parse: openai tool_calls extracted",
    #oc == 1 and oc[1].name == "suggest" and oc[1].arguments.level == "beginner")

  local anthropic = { content = {
    { type = "text", text = "preamble", },
    { type = "tool_use", name = "suggest", input = { explanation = "y", level = "advanced" }, },
  }, }
  local ac = t.extract_tool_calls(anthropic, true)
  check("parse: anthropic tool_use extracted",
    #ac == 1 and ac[1].name == "suggest" and ac[1].arguments.level == "advanced")

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
  check("level_index: ordered beginner < master",
    utils.level_index("beginner") == 1 and utils.level_index("master") == #config.LEVELS)
  check("level_index: unknown level -> nil", utils.level_index("wizard") == nil)
  check("normalize_level: known level passes through", utils.normalize_level("Advanced") == "advanced")
  check("normalize_level: explicit none preserved", utils.normalize_level("none") == "none")
  check("normalize_level: unknown degrades to lowest (never silent)",
    utils.normalize_level("wizard") == config.LEVELS[1] and utils.normalize_level(nil) == config.LEVELS[1])
end

-- skill-level gate + progression (store): the user starts at the lowest level,
-- only sees features at/below it, and unlocks the next by engaging at the top
-- level. XDG_DATA_HOME isolates progress.json.
do
  config.options.unlock_threshold = 3
  local lang = "progress-probe-lang"
  check("progress: starts at the lowest level", store.unlocked_level(lang) == config.LEVELS[1])
  check("gate: beginner unlocked from the start", store.is_unlocked(lang, "beginner") == true)
  check("gate: a higher level is locked initially", store.is_unlocked(lang, "intermediate") == false)
  check("gate: an unknown level is never unlocked", store.is_unlocked(lang, "wizard") == false)

  -- engaging with a NOT-yet-top level doesn't advance you
  store.record_interaction(lang, "intermediate")
  check("progress: engaging above the top level doesn't advance", store.unlocked_level(lang) == config.LEVELS[1])

  -- engage threshold-1 times at the top level: still not unlocked
  store.record_interaction(lang, "beginner")
  store.record_interaction(lang, "beginner")
  check("progress: below threshold keeps current level", store.unlocked_level(lang) == config.LEVELS[1])
  -- the threshold-th engagement unlocks the next level and resets the counter
  store.record_interaction(lang, "beginner")
  check("progress: reaching the threshold unlocks the next level",
    store.unlocked_level(lang) == "intermediate")
  check("gate: newly unlocked level now shows", store.is_unlocked(lang, "intermediate") == true)
  check("gate: the level after that is still locked", store.is_unlocked(lang, "advanced") == false)

  -- progress is per-language: an untouched language is still at the start
  check("progress: independent per language", store.unlocked_level("other-lang") == config.LEVELS[1])
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

-- progression: persists across a reload, and caps at the top level
do
  config.options.unlock_threshold = 1
  local lang = "persist-progress-lang"
  store.record_interaction(lang, config.LEVELS[1]) -- threshold 1 -> unlock level 2
  package.loaded["learning.store"] = nil
  check("progress: level persists across a module reload",
    require("learning.store").unlocked_level(lang) == config.LEVELS[2])
  store = require("learning.store")

  -- drive a fresh language all the way to the top level, then past it
  local top = "cap-lang"
  for _ = 1, #config.LEVELS do store.record_interaction(top, store.unlocked_level(top)) end
  check("progress: never advances past the highest level",
    store.unlocked_level(top) == config.LEVELS[#config.LEVELS])
  -- engaging at the cap is a harmless no-op (no crash, stays at master)
  store.record_interaction(top, config.LEVELS[#config.LEVELS])
  check("progress: engaging at the cap is a no-op",
    store.unlocked_level(top) == config.LEVELS[#config.LEVELS])
end

-- model-dependent checks — need a tool-calling provider. every live request is
-- independent, so they fire CONCURRENTLY (one curl each) and settle in a couple
-- of waves rather than one slow call at a time. transient failures (the free
-- keyless models occasionally drop a call) are retried in later waves, so a
-- network hiccup isn't mistaken for a wrong answer.
local fixtures = require("tests.fixtures")

-- rank a skill level low→high; "none" (nothing to teach) sits above "master" as
-- the highest possible bar, so a subtle case the model declines to teach still
-- separates correctly from an obvious beginner miss.
local LEVEL_RANK = { beginner = 1, intermediate = 2, advanced = 3, master = 4, none = 5, }

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

-- before = the function's signature stub, so the diff the model sees is its body
local function suggest_job(before, after, ft)
  local change = diff.compute(before, after)
  return change, change and function(cb) ai.suggestion(change, ft or "python", {}, cb) end or nil
end

-- two FRESHLY GENERATED "beginner" edits (novel code each run, via the keyless
-- free Zen models) drive shape invariants; "beginner" is the level the free
-- generator produces reliably. generation uses a blocking call, so it stays
-- sequential; the classification requests it feeds into the batch below do not.
local generated = {}
for i = 1, 2 do
  local fx = fixtures.fresh("beginner")
  local change, job = suggest_job(fx.before, fx.after, fx.ft)
  generated[i] = {
    tag = "suggest[" .. fx.name .. (fx.generated and "" or "/FALLBACK") .. "]",
    change = change,
    job = job,
  }
end

-- one concurrent batch: the generated-fixture classifications, the curated
-- per-level separation set, and the on-demand explain.
local jobs = {}
for i, fx in ipairs(generated) do
  if fx.job then jobs["gen" .. i] = fx.job end
end
for _, lvl in ipairs(config.LEVELS) do
  for i, body in ipairs(fixtures.CURATED[lvl]) do
    local _, job = suggest_job({ body[1], "    pass", }, body)
    if job then jobs[lvl .. i] = job end
  end
end
jobs.explain = function(cb) ai.explain("squares = [x * x for x in range(10)]", "python", cb) end

local R = gather(jobs, 4)

-- shape invariants over the generated fixtures. assertions are invariants, never
-- a fixed sentence.
for i, fx in ipairs(generated) do
  check(fx.tag .. ": fixture is a non-trivial edit", fx.change ~= nil)
  if fx.change then
    local s = R["gen" .. i]
    check(fx.tag .. ": returns a suggestion", s ~= nil)
    if s then
      check(fx.tag .. ": level is a known classification",
        type(s.level) == "string" and LEVEL_RANK[s.level] ~= nil, tostring(s.level))
      check(fx.tag .. ": feature is a non-empty string",
        type(s.feature) == "string" and #s.feature > 0, tostring(s.feature))
      check(fx.tag .. ": any returned edit is well-formed",
        s.edit == nil or utils.valid_edit(s.edit) ~= nil)
    end
  end
end

-- level ordering: the curated fixtures should classify in roughly increasing
-- order beginner < intermediate < advanced < master, so the progressive gate
-- reveals features in pedagogical order. weak models are noisy in the middle, so
-- assert the robust shape: the easy extreme lands lowest, the hard extreme
-- highest, with a clear total spread (middles only have to fall in between).
do
  local function avg(t) local s = 0 for _, v in ipairs(t) do s = s + v end return #t > 0 and s / #t or 0 end
  local function cluster(lvl)
    local o = {}
    for i = 1, #fixtures.CURATED[lvl] do
      local s = R[lvl .. i]
      if s and type(s.level) == "string" then table.insert(o, LEVEL_RANK[s.level]) end
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
  check("levels: classifications trend from beginner (low) to master (high)",
    all_scored and extremes_ordered and (avgs[hi] - avgs[lo]) >= 1.0,
    table.concat(detail, " "))
end

-- explain answers about the *selected* code (distinctive construct -> named)
do
  local s = R.explain
  check("explain: returns an explanation", s ~= nil and s.summary ~= nil)
  check("explain: relevant to selection (mentions comprehension)",
    s ~= nil and (s.summary or ""):lower():find("comprehension") ~= nil,
    s and (s.summary or ""):sub(1, 60) or "nil")
end

-- ===========================================================================
print(string.rep("=", 60))
print(("RESULT: %d passed, %d failed"):format(pass, #failed))
for _, n in ipairs(failed) do print("  FAILED: " .. n) end
vim.cmd(#failed > 0 and "cq 1" or "qa")

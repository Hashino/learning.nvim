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
-- Model-dependent checks (suggestion/explain relevance, eagerness) need a
-- provider that supports tool calling; the deterministic checks do not.

local config   = require("learning.config")
local diff     = require("learning.diff")
local utils    = require("learning.utils")
local store    = require("learning.store")
local ai       = require("learning.ai")
local window   = require("learning.window")
local learning = require("learning")

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

--- runs an async `fn(cb)` and blocks until it calls back, returning the result
local function await(fn, timeout)
  local done, result = false, nil
  fn(function(r) result, done = r, true end)
  vim.wait(timeout or 60000, function() return done end, 100)
  return result
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

local function approx(a, b) return type(a) == "number" and math.abs(a - b) < 1e-9 end

-- response parsing (ai._test): both provider shapes, fallbacks, malformed input.
-- this is what a single live provider can never exercise — the OTHER shape.
do
  local t = ai._test
  local openai = { choices = { { message = { tool_calls = {
    { type = "function", ["function"] = { name = "suggest", arguments = '{"explanation":"x","importance":8}' }, },
  }, }, }, }, }
  local oc = t.extract_tool_calls(openai, false)
  check("parse: openai tool_calls extracted",
    #oc == 1 and oc[1].name == "suggest" and oc[1].arguments.importance == 8)

  local anthropic = { content = {
    { type = "text", text = "preamble", },
    { type = "tool_use", name = "suggest", input = { explanation = "y", importance = 9 }, },
  }, }
  local ac = t.extract_tool_calls(anthropic, true)
  check("parse: anthropic tool_use extracted",
    #ac == 1 and ac[1].name == "suggest" and ac[1].arguments.importance == 9)

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

-- importance normalization edge values (the 9 -> 0.9 bug class)
do
  local ni = ai._test.normalize_importance
  check("normalize: 8 -> 0.8", approx(ni(8), 0.8))
  check("normalize: 10 -> 1", approx(ni(10), 1))
  check("normalize: already 0.9 stays", approx(ni(0.9), 0.9))
  check("normalize: >10 clamps to 1", approx(ni(15), 1))
  check("normalize: negative clamps to 0", approx(ni(-3), 0))
  check("normalize: nil -> 0", approx(ni(nil), 0))
  check("normalize: numeric string '7' -> 0.7", approx(ni("7"), 0.7))
end

-- eagerness gate arithmetic at the boundaries (no model needed)
do
  local function at(e, imp)
    config.options.eagerness = e
    return utils.meets_eagerness(imp)
  end
  check("gate: eagerness 0 never shows", at(0, 1) == false and at(0, 0.5) == false)
  check("gate: eagerness 1 shows any importance", at(1, 0) == true)
  check("gate: 0.25 shows iff importance >= 0.75", at(0.25, 0.75) == true and at(0.25, 0.74) == false)
  check("gate: 0.75 shows iff importance >= 0.25", at(0.75, 0.25) == true and at(0.75, 0.24) == false)
  check("gate: nil importance treated as 0", at(0.75, nil) == false)
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

-- model-dependent checks — need a tool-calling provider

local sum_edit = {
  start = 7,
  old_content = { "def total(numbers):", "    result = 0", "    for n in numbers:", "        result = result + n", "    return result" },
  new_content = { "def total(numbers):", "    return sum(numbers)" },
}

-- auto-suggestion is relevant to the edited lines
do
  local s = await(function(cb) ai.suggestion(sum_edit, "python", {}, cb) end)
  check("suggest: returns a suggestion", s ~= nil)
  check("suggest: relevant to the edit (mentions sum)",
    s ~= nil and ((s.summary or "") .. (s.feature or "")):lower():find("sum") ~= nil,
    s and tostring(s.feature) or "nil")
  check("suggest: importance normalized to 0..1",
    s ~= nil and type(s.importance) == "number" and s.importance >= 0 and s.importance <= 1,
    s and tostring(s.importance) or "nil")
end

-- eagerness gate: run 3x at 0.25 and 0.75; the decision must be CONSISTENT
local function gate(imp)
  return config.options.eagerness > 0 and (imp or 0) >= 1 - config.options.eagerness
end
local function eagerness_runs(level)
  config.options.eagerness = level
  local decisions, imps = {}, {}
  for i = 1, 3 do
    local s = await(function(cb) ai.suggestion(sum_edit, "python", {}, cb) end)
    imps[i] = s and s.importance or "nil"
    decisions[i] = s ~= nil and gate(s.importance) or false
  end
  local consistent = decisions[1] == decisions[2] and decisions[2] == decisions[3]
  return consistent, decisions, imps
end
do
  local c25, d25, i25 = eagerness_runs(0.25)
  check("eagerness 0.25: same decision across 3 runs (consistent)", c25,
    "decisions=" .. vim.inspect(d25) .. " importance=" .. vim.inspect(i25))
  local c75, d75, i75 = eagerness_runs(0.75)
  check("eagerness 0.75: same decision across 3 runs (consistent)", c75,
    "decisions=" .. vim.inspect(d75) .. " importance=" .. vim.inspect(i75))
  check("eagerness: idiomatic edit shows at both 0.25 and 0.75",
    d25[1] == true and d75[1] == true, "0.25=" .. tostring(d25[1]) .. " 0.75=" .. tostring(d75[1]))
end

-- explain answers about the *selected* code (distinctive construct -> named)
do
  local s = await(function(cb) ai.explain("squares = [x * x for x in range(10)]", "python", cb) end)
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

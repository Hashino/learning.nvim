-- Non-deterministic test fixtures: on each run the model *generates fresh code*
-- to be tested, rather than us templating it. Inspired by askai.nvim's "invent a
-- new prompt every run" plan — here the edit under test is invented by the model,
-- so the live suite never overfits a memorized snippet and is forced to hold its
-- invariants over genuinely novel input each run.
--
-- Each fixture is a short Python edit (`before` → `after`, the last line just
-- typed) whose `after` still misses one idiomatic builtin/feature the plugin
-- should teach. Assertions over these must be invariants (shape, importance
-- range, idiom relevance), never a hardcoded expected sentence.
--
-- Generation runs against the KEYLESS free OpenCode Zen models (no API key, no
-- auth header) so the suite is runnable by anyone — decoupled from whatever
-- provider the plugin-under-test uses. A deterministic template is used only if
-- generation fails, so a transient provider hiccup degrades instead of failing
-- the whole suite.

local diff = require("learning.diff")

local Fixtures = {}

-- keyless free Zen provider (from ~/.pi/agent/models.json: opencode-free).
-- rotate models for extra between-run variety; all need no Authorization header.
local FREE_URL = "https://opencode.ai/zen/v1/chat/completions"
local FREE_MODELS = { "deepseek-v4-flash-free", "big-pickle", "nemotron-3-ultra-free", }

-- ── request (forced tool_choice, degrading to "auto" for thinking models) ──
local function post(payload)
  local cmd = { "curl", "-s", "--max-time", "90", "-X", "POST", FREE_URL,
    "-H", "Content-Type: application/json", "-d", vim.json.encode(payload), }
  local ok, decoded = pcall(vim.json.decode, vim.fn.system(cmd))
  return ok and decoded or nil
end

local function request(prompt, tool)
  local base = {
    model = FREE_MODELS[math.random(#FREE_MODELS)],
    messages = { { role = "user", content = prompt, }, },
    tools = { tool, },
    temperature = 1.0, -- push variety between runs
  }
  base.tool_choice = { type = "function", ["function"] = { name = tool["function"].name, }, }
  local decoded = post(base)
  if type(decoded) == "table" and decoded.error
      and tostring(decoded.error.message or ""):find("tool_choice") then
    base.tool_choice = "auto" -- thinking models reject a forced tool_choice
    decoded = post(base)
  end
  local msg = type(decoded) == "table" and decoded.choices and decoded.choices[1]
      and decoded.choices[1].message
  local tc = msg and msg.tool_calls and msg.tool_calls[1]
  if not (tc and tc["function"]) then return nil end
  local aok, args = pcall(vim.json.decode, tc["function"].arguments)
  return aok and args or nil
end

-- ── AI-generated fixture ──────────────────────────────────────────────────
local PROMPT = table.concat({
  "You generate test fixtures for a Python-idioms tutor.",
  "Invent a SHORT, realistic Python snippet (a few lines) that a learner might",
  "write and that MISSES exactly one common idiomatic Python feature — e.g. a",
  "manual accumulator loop instead of sum(), a manual index instead of enumerate,",
  "string building with + instead of ''.join(), an append-loop instead of a list",
  "comprehension, range(len(x)) indexing, a manual max/min, etc.",
  "Vary the identifiers, values and structure so it is DIFFERENT every time —",
  "avoid textbook names like 'numbers'/'result'.",
  "",
  "Return two versions via the make_fixture tool:",
  "- after: the FULL snippet, including the multi-line block that misses the idiom",
  "  (the entire manual loop / range(len()) indexing / string += / append-loop).",
  "- before: the SAME snippet with that whole block removed — the state just before",
  "  the user wrote it (e.g. only the function signature or the surrounding lines).",
  "So the DIFF (lines in `after` but not `before`) IS the idiom-missing block itself:",
  "at least 2-3 lines that clearly show the pattern, never a single trailing line.",
  "Also give `idiom` (the missing feature) and `terms` (1-3 lowercase words the",
  "correct idiom is described with, e.g. ['sum'], ['enumerate'], ['join']).",
}, "\n")

local TOOL = {
  type = "function",
  ["function"] = {
    name = "make_fixture",
    description = "Return a fresh Python edit that misses one idiomatic feature.",
    parameters = {
      type = "object",
      properties = {
        before = { type = "array", items = { type = "string", }, description = "lines before the last edit", },
        after = { type = "array", items = { type = "string", }, description = "lines after the last edit", },
        idiom = { type = "string", description = "the missing idiomatic feature", },
        terms = { type = "array", items = { type = "string", }, description = "1-3 lowercase idiom terms", },
      },
      required = { "before", "after", "idiom", "terms", },
    },
  },
}

local function lines_ok(t)
  if type(t) ~= "table" or #t == 0 then return false end
  for _, l in ipairs(t) do if type(l) ~= "string" then return false end end
  return true
end

--- generate one fresh fixture via the model; nil if it can't be made valid.
local function generate()
  local a = request(PROMPT, TOOL)
  if not (a and lines_ok(a.before) and lines_ok(a.after)) then return nil end
  -- the edit must be a real (non-trivial) change, or there's nothing to suggest on
  if diff.compute(a.before, a.after) == nil then return nil end
  local terms = lines_ok(a.terms) and a.terms or { tostring(a.idiom or ""):lower(), }
  return {
    name = "ai:" .. tostring(a.idiom),
    ft = "python",
    start = 0,
    before = a.before,
    after = a.after,
    terms = terms,
    generated = true,
  }
end

-- deterministic safety net (only used if generation fails) — clearly marked so a
-- fallback is visible in test output rather than masquerading as a fresh fixture.
local function fallback()
  return {
    name = "fallback:loop->sum",
    ft = "python",
    start = 0,
    before = { "def total(xs):", "    acc = 0", "    for x in xs:", "        pass", },
    after = { "def total(xs):", "    acc = 0", "    for x in xs:", "        acc += x", "    return acc", },
    terms = { "sum", },
    generated = false,
  }
end

--- a freshly model-generated edit fixture (falls back to a template on failure).
---@return { name: string, ft: string, start: integer, before: string[], after: string[], terms: string[], generated: boolean }
function Fixtures.fresh()
  for _ = 1, 3 do
    local f = generate()
    if f then return f end
  end
  return fallback()
end

return Fixtures

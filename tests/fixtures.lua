-- Non-deterministic test fixtures: on each run a random free model *writes the
-- code under test*, rather than us templating it. Inspired by askai.nvim's
-- "invent a new prompt every run" plan — here the snippet is invented by the
-- model, so the live suite never overfits a memorized example and must hold its
-- invariants over genuinely novel input each run.
--
-- Two categories drive the skill-level checks:
--   "obvious" — a function missing an obvious, well-known feature (should
--               classify at a low/beginner skill level).
--   "subtle"  — a function that merely could be slightly more idiomatic (should
--               classify at a higher skill level, or "none").
-- Assertions over these must be invariants (shape, a known level, and obvious
-- classifying below subtle), never a hardcoded expected sentence.
--
-- Generation runs against the KEYLESS free OpenCode Zen models (no API key, no
-- auth header) so the suite is runnable by anyone — decoupled from whatever
-- provider the plugin-under-test uses. A deterministic template is used only if
-- generation fails, so a transient provider hiccup degrades instead of failing
-- the whole suite.

local diff = require("learning.diff")

local Fixtures = {}

-- keyless free Zen provider (from ~/.pi/agent/models.json: opencode-free).
-- a random model writes each fixture, for extra between-run variety.
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

-- ── AI-generated fixtures ─────────────────────────────────────────────────
local PROMPTS = {
  beginner = table.concat({
    "Generate a single short Python function (3-8 lines) that MISSES an obvious,",
    "well-known Python feature — a clear idiomatic improvement a beginner would",
    "miss (e.g. a manual loop that should use a builtin, range(len()) indexing,",
    "string concatenation that should use join). Vary it every time.",
  }, "\n"),
  advanced = table.concat({
    "Generate a single short Python function (3-8 lines) that WORKS FINE and is",
    "already reasonable, but could be written in a SLIGHTLY more idiomatic way —",
    "a minor, non-obvious refinement, nothing a beginner would obviously miss.",
    "Vary it every time.",
  }, "\n"),
}

local TOOL = {
  type = "function",
  ["function"] = {
    name = "make_fixture",
    description = "Return a single Python function as the code under test.",
    parameters = {
      type = "object",
      properties = {
        code = { type = "array", items = { type = "string", }, description = "the function, one string per line", },
        note = { type = "string", description = "a few words naming the feature/refinement", },
      },
      required = { "code", },
    },
  },
}

local function lines_ok(t)
  if type(t) ~= "table" or #t == 0 then return false end
  for _, l in ipairs(t) do if type(l) ~= "string" then return false end end
  return true
end

-- treat the whole generated function as a just-typed edit: empty buffer -> code,
-- so the diff the plugin sees is the function itself.
local EMPTY = { "", }

--- generate one fresh fixture of `category` via the model; nil if invalid.
---@param category "beginner"|"advanced"
local function generate(category)
  local a = request(PROMPTS[category], TOOL)
  if not (a and lines_ok(a.code)) then return nil end
  if diff.compute(EMPTY, a.code) == nil then return nil end -- must be a real edit
  return {
    name = category .. ":" .. (a.note or "?"),
    category = category,
    ft = "python",
    before = EMPTY,
    after = a.code,
    generated = true,
  }
end

-- deterministic safety net (only if generation fails) — clearly marked.
local FALLBACKS = {
  beginner = {
    "def total(xs):", "    acc = 0", "    for x in xs:", "        acc = acc + x", "    return acc",
  },
  advanced = {
    "def is_empty(xs):", "    if len(xs) == 0:", "        return True", "    return False",
  },
}
local function fallback(category)
  return {
    name = "fallback:" .. category,
    category = category,
    ft = "python",
    before = EMPTY,
    after = FALLBACKS[category],
    generated = false,
  }
end

--- a freshly model-generated fixture of `category` (falls back on failure).
---@param category "beginner"|"advanced"
---@return { name: string, category: string, ft: string, before: string[], after: string[], generated: boolean }
function Fixtures.fresh(category)
  for _ = 1, 3 do
    local f = generate(category)
    if f then return f end
  end
  return fallback(category)
end

-- hand-curated clean fixtures (each the `after` function body), grouped by the
-- skill level the missed feature belongs to. they anchor the live classification
-- test: the model should rank these roughly in this order (beginner lowest,
-- master highest). the free generator can't reliably produce the higher levels
-- (it tends to emit obvious misses), so these are fixed and ordering-verified.
-- Levels mirror learning.config.LEVELS.
Fixtures.CURATED = {
  -- a clear miss of a core builtin
  beginner = {
    { "def total(xs):", "    acc = 0", "    for x in xs:", "        acc = acc + x", "    return acc", },
    { "def show(items):", "    for i in range(len(items)):", "        print(i, items[i])", },
  },
  -- an everyday idiom a beginner could easily miss
  intermediate = {
    { "def pairs(a, b):", "    for i in range(len(a)):", "        print(a[i], b[i])", },
    { "def get_or_none(d, k):", "    if k in d:", "        return d[k]", "    return None", },
  },
  -- a non-obvious refinement of already-working code
  advanced = {
    { "def sq_sum(xs):", "    return sum([x * x for x in xs])", },
    { "def is_empty(xs):", "    if len(xs) == 0:", "        return True", "    return False", },
  },
  -- an expert-level construct most code never needs
  master = {
    { "def squares_sum(xs):", "    squares = [x * x for x in xs]", "    return sum(squares)", },
    { "def first_even(xs):", "    for x in xs:", "        if x % 2 == 0:", "            return x", "    return None", },
  },
}

return Fixtures

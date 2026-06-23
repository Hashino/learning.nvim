local config = require("learning.config")
local utils  = require("learning.utils")

---@class learning.Store [Hashino/learning.nvim] persists how often a feature
--- has been dismissed (so repeatedly-rejected suggestions can be suppressed) and
--- the user's per-language skill-level progress.
local Store = {}

--- directory data lives in: ~/.local/share/nvim/learning.nvim/
local DIR = vim.fs.joinpath(vim.fn.stdpath("data"), "learning.nvim")
local FILE = vim.fs.joinpath(DIR, "dismissed.json")
local PROGRESS_FILE = vim.fs.joinpath(DIR, "progress.json")

--- in-memory cache of the on-disk table. shape: { [language] = { [feature] = count } }
---@type table<string, table<string, integer>>|nil
local cache = nil

--- in-memory cache of the per-language progress table.
--- shape: { [language] = { level = string, knows = { [feature] = { level, used } } } }
---@type table<string, { level: string, knows: table<string, { level: string, used: integer }> }>|nil
local progress_cache = nil

--- normalizes a language/feature label into a stable lookup key
---@param s string?
---@return string
local function key(s)
  return vim.trim((s or ""):lower())
end

--- reads and decodes a json file into a table, or {} when absent/corrupt
---@param path string
---@return table
local function read_json(path)
  local found, lines = pcall(vim.fn.readfile, path)
  if found then
    local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
    if ok and type(decoded) == "table" then
      return decoded
    end
  end
  return {}
end

--- loads the dismissal table from disk into the cache (once)
---@return table<string, table<string, integer>>
local function load()
  if cache then return cache end
  cache = read_json(FILE)
  return cache
end

--- loads the per-language progress table from disk into the cache (once)
---@return table<string, { level: string, knows: table<string, { level: string, used: integer }> }>
local function load_progress()
  if progress_cache then return progress_cache end
  progress_cache = read_json(PROGRESS_FILE)
  return progress_cache
end

--- writes a table to disk as json, creating the directory if needed
---@param path string
---@param data table
local function persist_json(path, data)
  vim.fn.mkdir(DIR, "p")
  vim.fn.writefile({ vim.json.encode(data), }, path)
end

--- writes the dismissal cache back to disk
local function persist()
  persist_json(FILE, cache or {})
end

--- how many times the given feature has been dismissed for a language
---@param language string?
---@param feature string?
---@return integer
local function count(language, feature)
  local lang_key, feat_key = key(language), key(feature)
  if feat_key == "" then return 0 end
  local data = load()
  return (data[lang_key] or {})[feat_key] or 0
end

--- true once a feature has been dismissed at least `dismiss_threshold` times
--- for the given language; such suggestions should no longer be shown.
---@param language string?
---@param feature string?
---@return boolean
function Store.is_suppressed(language, feature)
  return count(language, feature) >= config.options.dismiss_threshold
end

--- records one dismissal of a feature for a language and saves to disk
---@param language string?
---@param feature string?
function Store.record_dismiss(language, feature)
  local feat_key = key(feature)
  if feat_key == "" then return end

  local lang_key = key(language)
  local data = load()
  data[lang_key] = data[lang_key] or {}
  data[lang_key][feat_key] = (data[lang_key][feat_key] or 0) + 1
  persist()
end

--- the features already suppressed for a language, so the prompt can ask the
--- model to avoid re-teaching them in the first place.
---@param language string?
---@return string[]
function Store.suppressed_features(language)
  local lang_key = key(language)
  local data = load()
  local out = {}
  for feat, c in pairs(data[lang_key] or {}) do
    if c >= config.options.dismiss_threshold then
      table.insert(out, feat)
    end
  end
  return out
end

-- ── skill-level progression ───────────────────────────────────────────────
-- the user's level per language is INFERRED, never configured: everyone starts
-- at the lowest tier (config.LEVELS[1]) and is promoted purely by demonstrated
-- knowledge. each feature the evaluator sees the user use is recorded with a
-- `used` count; a feature is "known" once used >= know_threshold. when the user
-- knows `unlock_threshold` distinct features of a tier, the next tier unlocks.
-- being taught/drilled is NOT proof — only the evaluator seeing unprompted use is.

--- the progress record for a language, defaulting to the lowest tier. tolerates
--- old records (a pre-`knows` shape just yields an empty knowledge map).
---@param language string?
---@return { level: string, knows: table<string, { level: string, used: integer }> }
local function progress_for(language)
  local rec = load_progress()[key(language)]
  if type(rec) == "table" and utils.level_index(rec.level) then
    return { level = rec.level, knows = type(rec.knows) == "table" and rec.knows or {}, }
  end
  return { level = config.LEVELS[1], knows = {}, }
end

--- the highest skill level the user has unlocked for a language.
---@param language string?
---@return string one of config.LEVELS
function Store.unlocked_level(language)
  return progress_for(language).level
end

--- whether suggestions at `level` should be shown for a language yet, i.e. the
--- level is at or below the user's unlocked level. an unknown level is hidden.
---@param language string?
---@param level string?
---@return boolean
function Store.is_unlocked(language, level)
  local idx = utils.level_index(level)
  return idx ~= nil and idx <= utils.level_index(Store.unlocked_level(language))
end

--- whether the user has demonstrated `feature` enough (>= know_threshold) for it
--- to count as known — drives promotion and (stage 2) reminder routing.
---@param language string?
---@param feature string?
---@return boolean
function Store.is_known(language, feature)
  local rec = progress_for(language).knows[key(feature)]
  return type(rec) == "table" and (tonumber(rec.used) or 0) >= config.options.know_threshold
end

--- the deterministic stage-2 gate: whether a stage-1 evaluation is worth paying
--- the (heavy) teach call for. true only when the model found something to teach,
--- the feature isn't suppressed, and the user has unlocked its level.
---@param language string?
---@param level string?
---@param feature string?
---@return boolean
function Store.should_teach(language, level, feature)
  if level == nil or level == "none" then return false end
  if Store.is_suppressed(language, feature) then return false end
  return Store.is_unlocked(language, level)
end

--- the tier the user's knowledge has earned: a tier they know `unlock_threshold`
--- distinct features of lifts the ceiling to the NEXT tier (knowing a tier means
--- they're ready for the one above), capped at the top. derived from scratch and
--- monotonic (knowledge only grows), so the level never falls.
---@param knows table<string, { level: string, used: integer }>
---@return string one of config.LEVELS
local function ceiling_from(knows)
  local known_per_tier = {}
  for _, rec in pairs(knows) do
    if (tonumber(rec.used) or 0) >= config.options.know_threshold then
      local idx = utils.level_index(rec.level)
      if idx then known_per_tier[idx] = (known_per_tier[idx] or 0) + 1 end
    end
  end
  local top = 1
  for idx, n in pairs(known_per_tier) do
    if n >= config.options.unlock_threshold then
      top = math.max(top, math.min(idx + 1, #config.LEVELS))
    end
  end
  return config.LEVELS[top]
end

--- records the features a stage-1 evaluation saw the user already use. each bumps
--- that feature's `used` count; the level is then re-derived from what they now
--- know (it only ever rises). being taught/drilled does not count — only the
--- evaluator seeing unprompted use does.
---@param language string?
---@param items { feature: string, level: string }[]
function Store.record_knowledge(language, items)
  if type(items) ~= "table" or #items == 0 then return end

  local rec = progress_for(language)
  for _, item in ipairs(items) do
    local feat = key(item.feature)
    if feat ~= "" and utils.level_index(item.level) then
      local k = rec.knows[feat] or { level = item.level, used = 0, }
      k.level = item.level
      k.used = (tonumber(k.used) or 0) + 1
      rec.knows[feat] = k
    end
  end

  local derived = ceiling_from(rec.knows)
  if utils.level_index(derived) > utils.level_index(rec.level) then
    rec.level = derived
  end

  local data = load_progress()
  data[key(language)] = rec
  persist_json(PROGRESS_FILE, data)
end

--- the languages the user has any recorded progress in (for the progress view).
---@return string[]
function Store.languages()
  local out = {}
  for lang in pairs(load_progress()) do table.insert(out, lang) end
  table.sort(out)
  return out
end

--- a snapshot of progress in a language for display: the current tier, the
--- distinct features the user KNOWS (used >= know_threshold, sorted by tier), and
--- how many of those sit at the current tier (the count driving the next unlock).
---@param language string?
---@return { level: string, level_index: integer, known: { feature: string, level: string }[], known_at_tier: integer, threshold: integer, at_max: boolean }
function Store.progress_summary(language)
  local rec = progress_for(language)
  local idx = utils.level_index(rec.level) or 1
  local known, known_at_tier = {}, 0
  for feat, k in pairs(rec.knows) do
    if (tonumber(k.used) or 0) >= config.options.know_threshold then
      table.insert(known, { feature = feat, level = k.level, })
      if k.level == rec.level then known_at_tier = known_at_tier + 1 end
    end
  end
  table.sort(known, function(a, b)
    local ia, ib = utils.level_index(a.level) or 0, utils.level_index(b.level) or 0
    if ia ~= ib then return ia < ib end
    return a.feature < b.feature
  end)
  return {
    level = rec.level,
    level_index = idx,
    known = known,
    known_at_tier = known_at_tier,
    threshold = config.options.unlock_threshold,
    at_max = idx >= #config.LEVELS,
  }
end

return Store

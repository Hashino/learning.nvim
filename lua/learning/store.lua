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
--- shape: { [language] = { level = string, engaged = integer } }
---@type table<string, { level: string, engaged: integer }>|nil
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
---@return table<string, { level: string, engaged: integer }>
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
-- the user unlocks levels one at a time, per language. they start at the lowest
-- (config.LEVELS[1]); after engaging with `unlock_threshold` suggestions at
-- their current top level, the next one unlocks. only interactions AT the top
-- level advance progress — engaging with an already-mastered easier feature
-- doesn't push you forward.

--- the progress record for a language, defaulting to the lowest level.
---@param language string?
---@return { level: string, engaged: integer }
local function progress_for(language)
  local rec = load_progress()[key(language)]
  if type(rec) == "table" and utils.level_index(rec.level) then
    return { level = rec.level, engaged = tonumber(rec.engaged) or 0, }
  end
  return { level = config.LEVELS[1], engaged = 0, }
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

--- the deterministic stage-2 gate: whether a stage-1 classification is worth
--- paying the (heavy) teach call for. true only when the model found something
--- to teach, the feature isn't suppressed, and the user has unlocked its level.
---@param language string?
---@param level string?
---@param feature string?
---@return boolean
function Store.should_teach(language, level, feature)
  if level == nil or level == "none" then return false end
  if Store.is_suppressed(language, feature) then return false end
  return Store.is_unlocked(language, level)
end

--- records the user engaging with a shown suggestion (accept or dismiss). only
--- counts toward unlocking when the suggestion is at the current top level;
--- reaching `unlock_threshold` unlocks the next level and resets the counter.
---@param language string?
---@param level string?
function Store.record_interaction(language, level)
  local rec = progress_for(language)
  -- already at the cap, or the suggestion isn't at the level we're working on
  if level ~= rec.level or utils.level_index(rec.level) >= #config.LEVELS then return end

  rec.engaged = rec.engaged + 1
  if rec.engaged >= config.options.unlock_threshold then
    rec.level = config.LEVELS[utils.level_index(rec.level) + 1]
    rec.engaged = 0
  end

  local data = load_progress()
  data[key(language)] = rec
  persist_json(PROGRESS_FILE, data)
end

return Store

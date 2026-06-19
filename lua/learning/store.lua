local config = require("learning.config")

---@class learning.Store [Hashino/learning.nvim] persists how often a feature
--- has been dismissed so repeatedly-rejected suggestions can be suppressed.
local Store = {}

--- directory data lives in: ~/.local/share/nvim/learning.nvim/
local DIR = vim.fs.joinpath(vim.fn.stdpath("data"), "learning.nvim")
local FILE = vim.fs.joinpath(DIR, "dismissed.json")

--- in-memory cache of the on-disk table. shape: { [language] = { [feature] = count } }
---@type table<string, table<string, integer>>|nil
local cache = nil

--- normalizes a language/feature label into a stable lookup key
---@param s string?
---@return string
local function key(s)
  return vim.trim((s or ""):lower())
end

--- loads the dismissal table from disk into the cache (once)
---@return table<string, table<string, integer>>
local function load()
  if cache then return cache end

  cache = {}
  local found, lines = pcall(vim.fn.readfile, FILE)
  if found then
    local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
    if ok and type(decoded) == "table" then
      cache = decoded
    end
  end
  return cache
end

--- writes the cache back to disk, creating the directory if needed
local function persist()
  vim.fn.mkdir(DIR, "p")
  vim.fn.writefile({ vim.json.encode(cache or {}), }, FILE)
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

return Store

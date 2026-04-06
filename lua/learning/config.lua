local Config = {}

---@class LearningOptions
---@field enabled boolean wether plugin is enabled
Config.default_opts = {
  enabled = true,
}

Config.options = Config.default_opts

return Config

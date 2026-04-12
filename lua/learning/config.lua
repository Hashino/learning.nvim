local Config = {}


local HEIGHT = 25
local WIDTH = 75

---@class LearningOptions
---@field enabled boolean wether plugin is enabled
---@field keys LearningKeys keymaps for the plugin
---@field provider LearningOptionsProvider provider options for the ai provider
---@field win_config table window config for the edit window
Config.default_opts = {
  enabled = true,

  ---@class LearningOptionsProvider
  ---@field api_key string api key for the provider
  ---@field api_url string api url for the provider
  ---@field model string model to use for the provider
  provider = {
    api_key = "",
    api_url = "",
    model = "",
  },

  ---@class LearningKeys
  ---@field confirm string keymap to confirm the task
  ---@field dismiss string keymap to dismiss the task
  keys = {
    confirm = "<S-CR>",
    dismiss = "<Esc>",
  },


  -- window configs of the floating tasks editor
  -- see :h nvim_open_win() for available options
  win_config = {
    relative = "editor",

    width = WIDTH,
    height = HEIGHT,
    col = vim.o.columns - WIDTH,
    row = vim.o.lines - 3 - vim.o.cmdheight - HEIGHT,

    style = "minimal",
    border = "rounded",

    noautocmd = true,
  },
}

Config.options = Config.default_opts

return Config

local Config = {}

local HEIGHT = 25
local WIDTH = 75

---@class learning.Config
---@field eagerness? number how eager the plugin is to suggest (0 to 1)
---@field debounce_ms? number debounce interval in ms before sending accumulated edits (default 250)
---@field provider learning.Config.Provider provider options for the ai
---@field keys? learning.Config.Keys keymaps for the suggestion window
---@field win_config? table window config for the suggestion window (see :h nvim_open_win())
Config.options = {
  eagerness = 0.25,
  debounce_ms = 250,

  ---@class learning.Config.Provider
  ---@field api_key string api key for the provider
  ---@field api_url string api url for the provider
  ---@field model string model to use for the provider
  provider = { api_key = "", api_url = "", model = "", },

  ---@class learning.Config.Keys
  ---@field confirm string keymap to accept the suggestion
  ---@field dismiss string keymap to dismiss the suggestion
  keys = { confirm = "<S-CR>", dismiss = "<Esc>", },

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

return Config

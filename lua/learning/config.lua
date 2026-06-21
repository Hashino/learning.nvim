local Config = {}

local HEIGHT = 25
local WIDTH = 75

-- skill levels a missed feature can be classified into, from easiest to hardest.
-- the user starts with only the first unlocked and graduates through them by
-- engaging with suggestions (see learning.store). order is significant.
Config.LEVELS = { "beginner", "intermediate", "advanced", "master", }

---@class learning.Config
---@field unlock_threshold? number suggestions to engage with at the current top skill level before the next unlocks (default 5)
---@field debounce_ms? number debounce interval in ms before sending accumulated edits (default 250)
---@field dismiss_threshold? number times a feature must be dismissed before its auto-suggestions are suppressed
---@field ignored_buffers? string[]|fun():string[] elements are checked against buffer filetype/filename/filepath
---@field provider learning.Config.Provider provider options for the ai
---@field keys? learning.Config.Keys keymaps for the suggestion window
---@field win_config? table window config for the suggestion window (see :h nvim_open_win())
Config.options = {
  debounce_ms = 1500,

  -- the plugin shows suggestions for the language features the user has unlocked,
  -- starting at "beginner". after engaging (accepting or dismissing) this many
  -- suggestions at the current top level, the next level unlocks. per-language
  -- progress is tracked in ~/.local/share/nvim/learning.nvim/progress.json
  unlock_threshold = 5,

  -- after a feature's auto-suggestions are dismissed this many times (for a
  -- given language), they stop being shown. tracked in
  -- ~/.local/share/nvim/learning.nvim/dismissed.json
  dismiss_threshold = 2,

  -- doesn't suggest on buffers that match filetype/filename/filepath to
  -- entries. can be either a string array or a function that returns a
  -- string array. filepath can be relative or absolute
  ignored_buffers = {
    ".gitignore",
    ".git/COMMIT_EDITMSG",
  },

  ---@class learning.Config.Provider
  ---@field api_key string api key for the provider
  ---@field api_url string api url for the provider
  ---@field model string model to use for the provider
  ---@field headers? table<string, string> DEV ONLY: extra request headers, merged over the defaults. an empty-string value removes a default header (e.g. blanking Authorization for keyless dev endpoints). not a supported production feature.
  provider = { api_key = "", api_url = "", model = "", },

  ---@class learning.Config.Keys
  ---@field confirm? string keymap to accept the suggestion
  ---@field dismiss? string keymap to dismiss the suggestion
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

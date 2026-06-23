local Config = {}

local HEIGHT = 25
local WIDTH = 75

-- skill tiers a feature can belong to, from easiest to hardest. the user starts
-- at the first and is promoted as they demonstrate knowledge (see learning.store).
-- the level is inferred, never configured; order is significant. kept to three
-- because weak models reliably separate the extremes but blur finer gradations.
Config.LEVELS = { "beginner", "intermediate", "advanced", }

---@class learning.Config
---@field unlock_threshold? number distinct known features at the current top tier to demonstrate before the next tier unlocks (default 3)
---@field know_threshold? number times a feature must be demonstrated before it counts as "known" — gates promotion and reminders (default 3)
---@field drill_related_after? number failed drill submits before the shown example escalates to a closer one (default 1)
---@field drill_solution_after? number failed drill submits before the direct solution is shown (default 3)
---@field drill_timeout_ms? number ms of inactivity before an abandoned drill auto-closes (default 300000)
---@field debounce_ms? number debounce interval in ms before sending accumulated edits (default 250)
---@field dismiss_threshold? number times a feature must be dismissed before its auto-suggestions are suppressed
---@field ignored_buffers? string[]|fun():string[] elements are checked against buffer filetype/filename/filepath
---@field provider learning.Config.Provider provider options for the ai
---@field keys? learning.Config.Keys keymaps for the suggestion window
---@field win_config? table window config for the suggestion window (see :h nvim_open_win())
Config.options = {
  debounce_ms = 1500,

  -- skill tiers are inferred, never configured: everyone starts at "beginner" and
  -- is promoted as they demonstrate knowledge. a feature counts as "known" once it
  -- has been demonstrated `know_threshold` times; once the user knows
  -- `unlock_threshold` distinct features of their current top tier, the next tier
  -- unlocks. per-language progress: ~/.local/share/nvim/learning.nvim/progress.json
  unlock_threshold = 3,
  know_threshold = 3,

  -- active-recall drill scaffold: failed submits before the shown example
  -- escalates (a closer example, then the direct solution), and how long an
  -- untouched drill lingers before it auto-closes.
  drill_related_after = 1,
  drill_solution_after = 3,
  drill_timeout_ms = 300000,

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
  ---@field suggestion? { dismiss?: string, learn?: string } keys on a suggestion/reminder window
  ---@field drilling? { submit?: string, give_up?: string, dismiss?: string } keys (on the code buffer) during a drill
  keys = {
    -- a suggestion (or reminder) window: dismiss it, or enter a learn-mode drill
    suggestion = { dismiss = "<Esc>", learn = "<S-CR>", },
    -- during a drill you edit the code buffer itself: submit your attempt to be
    -- checked, give up (restores your original code), or dismiss (keeps what you
    -- wrote). avoid <Esc> here — it would collide with normal editing.
    drilling = { submit = "<S-CR>", give_up = "<C-g>", dismiss = "<C-x>", },
  },

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

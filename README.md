<div align="right">
  <a href="https://www.buymeacoffee.com/Hashino" target="_blank">
    <img src="https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png" 
    alt="Buy Me A Coffee" style="height: 24px !important;width: 104px !important;" >
</div>

# learning.nvim

<a href="https://dotfyle.com/plugins/Hashino/learning.nvim">
	<img src="https://dotfyle.com/plugins/Hashino/learning.nvim/shield?style=flat" />
</a>

learn the language features naturally as you code

![demo](https://raw.githubusercontent.com/Hashino/learning.nvim/main/demo/demo.gif)

## commands

- `:Learning explain` explains the visually selected code using AI
- `:Learning progress` shows your tier and learned features per language
- `:Learning disable` disables the plugin
- `:Learning enable` enables the plugin
- `:Learning toggle` toggles the plugin on and off

## suppressing repeated suggestions

Auto-suggestions teach a single language *feature* at a time. When you dismiss a
suggestion about the same feature (for the same language) `dismiss_threshold`
times (default `2`), future suggestions about that feature stop showing up.

dismissals are stored in `~/.local/share/nvim/learning.nvim/dismissed.json`.
Delete that file to start over.

## installation

lazy.nvim:
```lua
{
  "Hashino/learning.nvim",
  opts = {
      debounce_ms = 5000, -- debounce interval in ms before sending accumulated edits
      dismiss_threshold = 2, -- dismissals of a feature before its suggestions are suppressed

      ignored_buffers = { ".gitignore", ".git/COMMIT_EDITMSG" }, -- buffers to skip. string array or fun():string[], matched against filetype/filename/filepath
        
      -- if no provider is set the plugin fallbacks to an opencode free model
      provider = {
        api_key = "", -- your API key. be careful putting it in your dotfiles
        api_url = "", -- the URL for the API of your provider, example https://api.openai.com/v1/chat/completions
        model = "", -- the model you want to use, should be specified in the docs of your provider
      },
  },
}
```

vim.pack:
```lua
vim.pack.add({ "https://github.com/Hashino/learning.nvim", })
require("learning").setup({
  debounce_ms = 5000, -- debounce interval in ms before sending accumulated edits
  dismiss_threshold = 2, -- dismissals of a feature before its suggestions are suppressed

  ignored_buffers = { ".gitignore", ".git/COMMIT_EDITMSG" }, -- buffers to skip. string array or fun():string[], matched against filetype/filename/filepath

  -- if no provider is set the plugin fallbacks to an opencode free model
  provider = {
    api_key = "", -- your API key. be careful putting it in your dotfiles
    api_url = "", -- the URL for the API of your provider, example https://api.openai.com/v1/chat/completions
    model = "", -- the model you want to use, should be specified in the docs of your provider
  },
})
```

## providers

learning.nvim works with any OpenAI-compatible (or Anthropic) provider — set
`provider.api_url`, `provider.model`, and `provider.api_key`. If none is
provided it fallbacks to an opencode free model.

### model strength matters

> [!IMPORTANT]
> the quality of the experience relies a lot on the capabilities of the model.
> so better models result in a better experience. a lot was done to make the
> plugin work **well enough** with weaker models (like the free ones it uses as
> default), but the better solution is always a stronger model.

## keymap example

```lua
vim.keymap.set("v", "<leader>le", require("learning").explain,
    { desc = "[L]earning.nvim: [E]xplain selected text" })
```

## config

### default options

[see the source code for default options](https://github.com/Hashino/learning.nvim/blob/main/lua/learning/config.lua)

### example config

```lua
require("learning").setup({
  -- distinct features you must demonstrate at your current tier before the next
  -- unlocks (a feature counts once you've used it `know_threshold` times). your
  -- level is inferred from what you write — it is never set directly.
  unlock_threshold = 3,
  know_threshold = 3,

  -- debounce interval in ms before sending accumulated edits
  debounce_ms = 5000,

  -- dismissals of a feature (per language) before its suggestions are suppressed
  dismiss_threshold = 2,

  -- doesn't suggest on buffers that match filetype/filename/filepath to
  -- entries. can be either a string array or a function that returns a
  -- string array. filepath can be relative to cwd or absolute
  ignored_buffers = { ".gitignore", ".git/COMMIT_EDITMSG" },

  provider = {
    api_key = "", -- your API key. be careful putting it in your dotfiles
    api_url = "", -- the URL for the API of your provider, example https://api.openai.com/v1/chat/completions
    model = "",   -- the model you want to use, should be specified in the docs of your provider
  },

  -- keymaps, grouped by window: a suggestion/reminder, and a learn-mode drill
  keys = {
    suggestion = {
      learn = "<S-CR>",  -- enter a learn-mode drill for the feature
      dismiss = "<Esc>", -- dismiss the suggestion
    },
    -- during a drill you edit the code buffer itself, so avoid <Esc> here
    drilling = {
      submit = "<S-CR>",  -- check your attempt
      give_up = "<C-g>",  -- restore your original code and stop
      dismiss = "<C-x>",  -- keep what you wrote and stop
    },
  },

  -- window config for the suggestion window
  -- see :h nvim_open_win() for available options
  win_config = {
    border = "rounded",
  },
})

local learning = require("learning")

vim.keymap.set("v", "<leader>le", require("learning").explain,
    { desc = "[L]earning.nvim: [E]xplain selected text" })
vim.keymap.set("v", "<leader>le", require("learning").toggle,
    { desc = "[L]earning.nvim: [T]oggle" })
```

## testing

The `tests/` directory has an automated suite for forking or contributing.
`tests/run.lua` drives the real plugin end-to-end against a configured provider
and ships a keyless config that uses a free provider, so no API key is needed:

```sh
XDG_DATA_HOME=/tmp/learning-test nvim --headless \
  -u tests/init.lua -c "luafile tests/run.lua"
```

Only run it after a **big change to the main logic** (edit detection, prompts,
tool calls, skill-level classification/gating, or dismissal suppression), and run
it a few times since the backend is a live model. See [`tests/tests.md`](tests/tests.md)
for what it covers and an optional interactive smoke.

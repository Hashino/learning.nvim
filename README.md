<div align="right">
  <a href="https://www.buymeacoffee.com/Hashino" target="_blank">
    <img src="https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png" 
    alt="Buy Me A Coffee" style="height: 24px !important;width: 104px !important;" >
</div>

# learning.nvim

<a href="https://dotfyle.com/plugins/Hashino/learning.nvim">
	<img src="https://dotfyle.com/plugins/Hashino/learning.nvim/shield?style=flat" />
</a>

larn the language features naturally as you code

![demo1](https://raw.githubusercontent.com/Hashino/learning.nvim/main/demo1.gif)

![demo2](https://raw.githubusercontent.com/Hashino/learning.nvim/main/demo2.gif)

## commands

- `:Learning explain` explains the visually selected code using AI
- `:Learning disable` disables the plugin
- `:Learning enable` enables the plugin
- `:Learning toggle` toggles the plugin on and off

## suppressing repeated suggestions

Auto-suggestions teach a single language *feature* at a time. When you dismiss a
suggestion about the same feature (for the same language) `dismiss_threshold`
times (default `2`), future suggestions about that feature stop showing up.

Dismissals are stored in `~/.local/share/nvim/learning.nvim/dismissed.json`.
Delete that file to start over.

## installation

lazy.nvim:
```lua
{
  "Hashino/learning.nvim",
  opts = {
      eagerness = 0.25, -- how eager the plugin is to show suggestions, between 0 and 1. higher means more suggestions
      debounce_ms = 250, -- debounce interval in ms before sending accumulated edits
      dismiss_threshold = 2, -- dismissals of a feature before its suggestions are suppressed
      ignored_buffers = { ".gitignore", ".git/COMMIT_EDITMSG" }, -- buffers to skip. string array or fun():string[], matched against filetype/filename/filepath

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
  eagerness = 0.25, -- how eager the plugin is to show suggestions, between 0 and 1. higher means more suggestions
  debounce_ms = 250, -- debounce interval in ms before sending accumulated edits
      ignored_buffers = { ".gitignore", ".git/COMMIT_EDITMSG" }, -- buffers to skip. string array or fun():string[], matched against filetype/filename/filepath

  provider = {
    api_key = "", -- your API key. be careful putting it in your dotfiles
    api_url = "", -- the URL for the API of your provider, example https://api.openai.com/v1/chat/completions
    model = "", -- the model you want to use, should be specified in the docs of your provider
  },
})
```

## providers

learning.nvim works with any OpenAI-compatible (or Anthropic) provider — set
`provider.api_url`, `provider.model`, and `provider.api_key`.

For a capable **free** option, [OpenRouter](https://openrouter.ai)'s
`openai/gpt-oss-120b:free` is one of the best free coding models and works well
here:

```lua
provider = {
  api_url = "https://openrouter.ai/api/v1/chat/completions",
  api_key = "sk-or-...", -- your OpenRouter key
  model = "openai/gpt-oss-120b:free",
}
```

> Some free "thinking" models reject a _forced_ tool call; learning.nvim falls
> back to `tool_choice="auto"` automatically, so those models work too.

## keymap example

```lua
vim.keymap.set("v", "<leader>le", require("learning").explain, { desc = "[E]xp[l]ain selected code" })
```

## how it works

After each edit, the plugin snapshots the buffer and computes a diff to detect what changed. After a configurable debounce period of inactivity (`debounce_ms`), the changed lines (with surrounding context) are sent to an AI provider, which returns a relevant language tip as a structured suggestion. The suggestion is shown in a floating window — press `keys.confirm` to accept the edit or `keys.dismiss` to dismiss. An `eagerness` setting (0–1) controls how selectively suggestions are shown based on the AI's reported importance.

## config

### default options

[see the source code for default options](https://github.com/Hashino/learning.nvim/blob/main/lua/learning/config.lua)

### example config

```lua
require("learning").setup({
  -- how eager the plugin is to show suggestions, between 0 and 1.
  -- higher means more suggestions
  eagerness = 0.25,

  -- debounce interval in ms before sending accumulated edits
  debounce_ms = 250,

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

  -- keymaps for the suggestion window
  keys = {
    confirm = "<S-CR>", -- accept the suggested edit
    dismiss = "<Esc>",  -- dismiss the suggestion
  },

  -- window config for the suggestion window
  -- see :h nvim_open_win() for available options
  win_config = {
    border = "rounded",
  },
})

local learning = require("learning")

vim.keymap.set("v", "<leader>le", learning.explain, { desc = "[E]xp[l]ain selected code", })
vim.keymap.set("n", "<leader>lt", learning.toggle, { desc = "[T]oggle [l]earning.nvim", })
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
tool calls, eagerness gating, or dismissal suppression), and run it a few times
since the backend is a live model. See [`tests/tests.md`](tests/tests.md) for what
it covers and an optional interactive smoke.

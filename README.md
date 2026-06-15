<div align="right">
  <a href="https://www.buymeacoffee.com/Hashino" target="_blank">
    <img src="https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png" 
    alt="Buy Me A Coffee" style="height: 24px !important;width: 104px !important;" >
</div>

# learning.nvim

larn the language features naturally as you code

![demo1](https://raw.githubusercontent.com/Hashino/learning.nvim/main/demo1.gif)

![demo2](https://raw.githubusercontent.com/Hashino/learning.nvim/main/demo2.gif)

## commands

- `:Learning explain` explains the visually selected code using AI
- `:Learning disable` disables the plugin
- `:Learning enable` enables the plugin
- `:Learning toggle` toggles the plugin on and off

## installation

lazy.nvim:
```lua
{
  "Hashino/learning.nvim",
  opts = {
      eagerness = 0.25, -- how eager the plugin is to show suggestions, between 0 and 1. higher means more suggestions
      debounce_ms = 250, -- debounce interval in ms before sending accumulated edits
      ignored_buffers = {}, -- buffers to skip. string array or fun():string[], matched against filetype/filename/filepath

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
  ignored_buffers = {}, -- buffers to skip. string array or fun():string[], matched against filetype/filename/filepath

  provider = {
    api_key = "", -- your API key. be careful putting it in your dotfiles
    api_url = "", -- the URL for the API of your provider, example https://api.openai.com/v1/chat/completions
    model = "", -- the model you want to use, should be specified in the docs of your provider
  },
})
```

## keymap example

```lua
vim.keymap.set("v", "<leader>le", require("learning").explain, { desc = "Explain selected code" })
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

  -- doesn't suggest on buffers that match filetype/filename/filepath to
  -- entries. can be either a string array or a function that returns a
  -- string array. filepath can be relative to cwd or absolute
  ignored_buffers = { "markdown", "NvimTree", ".env" },

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

vim.keymap.set("v", "<leader>le", learning.explain, { desc = "Explain selected code", })
vim.keymap.set("n", "<leader>lt", learning.toggle, { desc = "Toggle learning.nvim", })
```

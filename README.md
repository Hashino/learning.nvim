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
      unlock_threshold = 5, -- suggestions to engage with at your current skill level before the next one unlocks
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
  unlock_threshold = 5, -- suggestions to engage with at your current skill level before the next one unlocks
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

### model strength matters

The plugin leans on the model to (1) judge whether your edit really misses an
idiomatic feature and (2) classify that miss into a skill level. **Stronger models
do both far more reliably.** Weaker/free models still work, but tend to collapse
the middle levels (everything reads as `beginner`) and occasionally miss a clear
suggestion — so the skill-level progression feels coarser. If suggestions seem
off or the levels never advance, try a more capable model before anything else.

## keymap example

```lua
vim.keymap.set("v", "<leader>le", require("learning").explain, { desc = "[E]xp[l]ain selected code" })
```

## how it works

After each edit, the plugin snapshots the buffer and computes a diff to detect what changed. After a configurable debounce period of inactivity (`debounce_ms`), the changed lines (with surrounding context) run through a two-stage cascade:

1. **classify** (cheap, every edit) — the model names the single language feature the change misses and ranks how obvious the miss is (`none` / `beginner` / `intermediate` / `advanced` / `master`).
2. a deterministic gate decides whether it's worth teaching: the feature must not be already-idiomatic (`none`), not [suppressed](#suppressing-repeated-suggestions), and at a skill level you've unlocked.
3. **teach** (only when the gate passes) — the model writes the tip and the concrete idiomatic rewrite.

Most edits stop at stage 1, so the common path is a single small request. When a suggestion does fire, it's shown in a floating window with the rewrite as a red/green diff above the explanation — press `keys.confirm` to accept the edit or `keys.dismiss` to dismiss.

Suggestions are revealed in pedagogical order: you start seeing only `beginner` tips, and each time you engage with `unlock_threshold` suggestions (accepting *or* dismissing) at your current top level, the next level unlocks. Progress is tracked **per language** in `~/.local/share/nvim/learning.nvim/progress.json` — so you can be a Python beginner and a Rust master at once. Delete that file to reset.

> **Breaking change:** the old `eagerness` option has been replaced by this
> automatic skill-level progression. If you still pass `eagerness`, it is ignored
> and Neovim shows a deprecation warning — remove it and tune `unlock_threshold`
> instead.

## config

### default options

[see the source code for default options](https://github.com/Hashino/learning.nvim/blob/main/lua/learning/config.lua)

### example config

```lua
require("learning").setup({
  -- how many suggestions you engage with (accept or dismiss) at your current top
  -- skill level before the next level unlocks. lower = level up faster.
  unlock_threshold = 5,

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
tool calls, skill-level classification/gating, or dismissal suppression), and run
it a few times since the backend is a live model. See [`tests/tests.md`](tests/tests.md)
for what it covers and an optional interactive smoke.

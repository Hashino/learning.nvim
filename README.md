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

Dismissals are stored in `~/.local/share/nvim/learning.nvim/dismissed.json`.
Delete that file to start over.

## installation

lazy.nvim:
```lua
{
  "Hashino/learning.nvim",
  opts = {
      unlock_threshold = 3, -- distinct features to demonstrate at your tier before the next unlocks
      know_threshold = 3, -- times you must use a feature before it counts as "known"
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
  unlock_threshold = 3, -- distinct features to demonstrate at your tier before the next unlocks
  know_threshold = 3, -- times you must use a feature before it counts as "known"
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
idiomatic feature, (2) place that miss in a skill tier, and (3) recognise the
features your code already uses well (which is what advances you). **Stronger
models do all three far more reliably.** Weaker/free models still work, but tend
to blur `beginner` and `intermediate` and occasionally miss a clear suggestion —
so progression feels coarser. If suggestions seem off or your level never
advances, try a more capable model before anything else.

## keymap example

```lua
vim.keymap.set("v", "<leader>le", require("learning").explain, { desc = "[E]xp[l]ain selected code" })
```

## how it works

After each edit, the plugin snapshots the buffer and computes a diff to detect what changed. After a configurable debounce period of inactivity (`debounce_ms`), the changed lines (with surrounding context) run through a two-stage cascade:

1. **evaluate** (cheap, every edit) — in one call the model reports *both* the single feature the change MISSES (`need_to_learn`, ranked `none` / `beginner` / `intermediate` / `advanced`) and the features the change DEMONSTRATES you already use well (`already_knows`). The demonstrated features are recorded — this is what advances your level.
2. a deterministic gate decides whether the miss is worth teaching: it must not be already-idiomatic (`none`), not [suppressed](#suppressing-repeated-suggestions), and at a skill tier you've reached.
3. **teach** (only when the gate passes) — the model writes the tip and the concrete idiomatic rewrite.

Most edits stop at stage 1, so the common path is a single small request. When a suggestion does fire, it's shown in a floating window with the explanation — press `keys.suggestion.learn` to enter a short **learn-mode drill**, or `keys.suggestion.dismiss` to dismiss (dismissing the same feature `dismiss_threshold` times suppresses it). In a drill the relevant lines are commented out as a reference and you reimplement them yourself; you `submit` your attempt to be checked, and worked examples are revealed if you get stuck (`give_up` restores your original code, `dismiss` keeps what you wrote). You learn by *doing*, not by accepting a fix. If you slip on a feature you've already demonstrated you know, you get a gentle **reminder** instead of a full lesson.

Your skill level is **inferred, never configured**: everyone starts at `beginner` and is promoted as the model sees you use features correctly — once you've demonstrated `unlock_threshold` distinct features of your current tier (each used at least `know_threshold` times) the next tier unlocks. Suggestions are therefore revealed in pedagogical order, and an already-skilled user simply climbs quickly as they write idiomatic code (it can take a little while for the plugin to calibrate to your true level). Progress is tracked **per language** in `~/.local/share/nvim/learning.nvim/progress.json` — so you can be a Python beginner and a Rust expert at once. Delete that file to reset. Suggestions show a mastery bar in their footer, and `:Learning progress` opens a full view of your tier and the features you've learned in each language.

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
  -- distinct features you must demonstrate at your current tier before the next
  -- unlocks (a feature counts once you've used it `know_threshold` times). your
  -- level is inferred from what you write — it is never set directly.
  unlock_threshold = 3,
  know_threshold = 3,

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

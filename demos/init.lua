-- Minimal config for learning.nvim demo (driven by VHS — see record.sh)

-- Set a typeable leader so VHS can trigger <leader>-mappings (the default `\`
-- is painful to send; `,le` reads clearly on screen).
vim.g.mapleader = ","

vim.opt.number = true
vim.opt.relativenumber = false

-- No swapfile: keeps recordings clean (no "found a swap file" prompt) and lets
-- the explain/drill quality-check tapes record in parallel against the same
-- demo.c without colliding.
vim.opt.swapfile = false

-- Install plugins via vim.pack (Neovim 0.12+)
vim.pack.add({
  { src = "https://github.com/rmehri01/onenord.nvim" },
  { src = "https://github.com/nvzone/showkeys" },
}, { confirm = false })

-- Configure showkeys: bottom-left position
require("showkeys").setup({
  position = "bottom-left",
})
require("showkeys").toggle()

-- Set onenord colorscheme
vim.cmd.colorscheme("onenord")

-- Per-buffer FileType setup for the recorded code:
--   * Treesitter highlighting so the code looks nice. This mirrors the user's
--     own config (nvim-treesitter `main` branch): the C parser + queries are
--     installed under ~/.local/share/nvim/site — already on the default
--     runtimepath here — and the `main` branch starts highlighting per-buffer
--     with vim.treesitter.start() rather than a global enable. pcall so the demo
--     still runs if the parser isn't installed (falls back to builtin syntax).
--   * Strip comment-continuation from formatoptions: VHS types each line
--     literally, so after a `// ...` comment line the default `formatoptions`
--     (c/r/o) would prepend `//` to the following code (e.g. `// int larger(...)`).
vim.api.nvim_create_autocmd("FileType", {
  callback = function(args)
    pcall(vim.treesitter.start, args.buf)
    vim.opt_local.formatoptions:remove({ "c", "r", "o" })
  end,
})

-- Match the demo file's 4-space style so auto-indented typing lines up.
vim.opt.expandtab = true
vim.opt.shiftwidth = 4
vim.opt.tabstop = 4

-- Add learning.nvim to runtime. record.sh copies this file into a temp config
-- dir, so its own path can't locate the repo — it exports LEARNING_PLUGIN_ROOT
-- (the repo root) for that case. Fall back to resolving relative to this file
-- (…/demos/init.lua) so a direct `nvim -u demos/init.lua` still works.
local plugin_root = os.getenv("LEARNING_PLUGIN_ROOT")
  or vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin_root)

-- The provider comes from the environment so no API key is committed (this dir
-- is in the repo). When all three of LEARNING_API_URL / LEARNING_API_KEY /
-- LEARNING_MODEL are set, that provider is used — record.sh points them at the
-- fast mercury endpoint. If any is missing, fall back to the free, keyless
-- provider the tests use, so the demo still runs out of the box.
local function env_provider()
  local url   = os.getenv("LEARNING_API_URL")
  local key   = os.getenv("LEARNING_API_KEY")
  local model = os.getenv("LEARNING_MODEL")
  if url and url ~= "" and key and key ~= "" and model and model ~= "" then
    return { api_url = url, api_key = key, model = model }
  end
  return require("learning.config").options.provider
end

require("learning").setup({
  -- A generous debounce so the suggestion fires ONCE, after typing stops, on the
  -- complete function. With a small debounce + a slow provider, a mid-typing edit
  -- triggers an `assess_need` that's still in flight when InsertLeave fires, so the
  -- final (complete-code) trigger is dropped by the in-flight guard and no window
  -- appears. 1500ms is longer than any inter-keystroke gap while typing the demo
  -- function, so only the post-Escape edit triggers the cascade.
  debounce_ms = 5000,
  dismiss_threshold = 2,
  provider = env_provider(),
  keys = {
    -- Rebound to keys VHS can send (Shift+Enter is not VHS-expressible)
    suggestion = { dismiss = "<Esc>", learn = "<C-l>" },
    drilling = { submit = "<C-s>", give_up = "<C-g>", dismiss = "<C-x>" },
  },
})

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

-- Add learning.nvim to runtime — resolved relative to this file (…/demo/init.lua)
-- so the demo works from any checkout without a hardcoded path.
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin_root)

-- Bootstrap showkeys using vim.pack (Neovim 0.12+)
vim.pack.add({ "https://github.com/nvzone/showkeys" }, { confirm = false })
require("showkeys").setup({ position = "bottom-right", timeout = 3, show_count = true })
require("showkeys").toggle()

-- The provider comes from the environment so no API key is committed (this dir
-- is in the repo). When all three of LEARNING_API_URL / LEARNING_API_KEY /
-- LEARNING_MODEL are set, that provider is used. If any is missing, fall back to
-- the free, keyless provider the tests use, so the demo still runs out of the box.
local function env_provider()
  local url   = os.getenv("LEARNING_API_URL")
  local key   = os.getenv("LEARNING_API_KEY")
  local model = os.getenv("LEARNING_MODEL")
  if url and url ~= "" and key and key ~= "" and model and model ~= "" then
    return { api_url = url, api_key = key, model = model }
  end
  return {
    api_url = "https://opencode.ai/zen/v1/chat/completions",
    api_key = "dummy",
    model   = "nemotron-3-ultra-free",
    headers = { Authorization = "" },
  }
end

require("learning").setup({
  -- A generous debounce so the suggestion fires ONCE, after typing stops, on the
  -- complete function. With a small debounce + a slow provider, a mid-typing edit
  -- triggers an `evaluate` that's still in flight when InsertLeave fires, so the
  -- final (complete-code) trigger is dropped by the in-flight guard and no window
  -- appears. 7000ms matches user's personal config for claude.
  debounce_ms = 7000,
  dismiss_threshold = 2,
  provider = env_provider(),
  keys = {
    -- Rebound to keys VHS can send (Shift+Enter is not VHS-expressible)
    suggestion = { dismiss = "<Esc>", learn = "<C-l>" },
    drilling = { submit = "<C-s>", give_up = "<C-g>", dismiss = "<C-x>" },
  },
})

-- explain the visual selection: <leader>le -> ",le" under the demo leader
vim.keymap.set("v", "<leader>le", function()
  require("learning").explain()
end, { desc = "[L]earning [E]xplain" })
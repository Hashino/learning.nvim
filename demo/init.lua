-- Minimal config for learning.nvim demo (driven by VHS — see record.sh)

-- Set a typeable leader so VHS can trigger <leader>-mappings (the default `\`
-- is painful to send; `,le` reads clearly on screen).
vim.g.mapleader = ","

vim.opt.number = true
vim.opt.relativenumber = false

-- Match the demo file's 4-space style so auto-indented typing lines up.
vim.opt.expandtab = true
vim.opt.shiftwidth = 4
vim.opt.tabstop = 4

-- Add learning.nvim to runtime — resolved relative to this file (…/demo/init.lua)
-- so the demo works from any checkout without a hardcoded path.
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
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
  return {
    api_url = "https://opencode.ai/zen/v1/chat/completions",
    api_key = "dummy",
    model   = "nemotron-3-ultra-free",
    headers = { Authorization = "" },
  }
end

require("learning").setup({
  debounce_ms = 250,
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

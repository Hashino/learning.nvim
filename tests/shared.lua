-- DEVELOPMENT ONLY — shared keyless setup for the learning.nvim test plan
-- (see tests/tests.md). It points at OpenCode Zen's free models, which are
-- reached with no Authorization header. `provider.headers` blanking Authorization
-- is a development-only escape hatch; do not use this pattern in real configs.
--
-- Returns a function so each `tests/init*.lua` can pick a different eagerness
-- level while sharing one provider/keymap definition.
--
---@param eagerness number eagerness level under test (0..1)
return function(eagerness)
  vim.opt.number = true
  vim.opt.relativenumber = false

  vim.opt.rtp:append("/home/hashino/.local/share/nvim/site/pack/core/opt/learning.nvim")

  require("learning").setup({
    eagerness = eagerness,
    debounce_ms = 250,
    dismiss_threshold = 2,
    provider = {
      api_url = "https://opencode.ai/zen/v1/chat/completions",
      api_key = "dummy",                 -- free Zen models; only needs to be non-empty
      model   = "nemotron-3-ultra-free", -- free; supports tool calling
      headers = { Authorization = "", }, -- DEV ONLY: Zen free tier wants no auth header
    },
    keys = { confirm = "<C-a>", },       -- PTY-sendable confirm key (see tests.md)
  })

  vim.keymap.set("v", "<leader>le", function()
    require("learning").explain()
  end, { desc = "[L]earning [E]xplain", })

  vim.notify("[learning.nvim tests] eagerness = " .. tostring(eagerness))
end

-- DEVELOPMENT ONLY — shared keyless setup for the learning.nvim test plan
-- (see tests/tests.md). It sets no `provider`, so setup() falls back to the free,
-- keyless OpenCode Zen default (the same one shipped in config.lua). To run the
-- suite faster against a real model, pass a `provider` override (e.g. mercury);
-- it replaces the free default verbatim.
--
-- Returns a function so each `tests/init*.lua` can override a few options (e.g.
-- unlock_threshold) while sharing one keymap definition.
--
---@param overrides? table options merged over the keyless defaults
return function(overrides)
  vim.opt.number = true
  vim.opt.relativenumber = false

  -- plugin root = the parent of this file's directory (…/tests/shared.lua),
  -- so the suite works from any checkout / cwd
  local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  vim.opt.rtp:append(plugin_root)

  require("learning").setup(vim.tbl_deep_extend("force", {
    -- unlock_threshold left at its default; the runner drives progression
    -- explicitly and the smoke test starts every language at "beginner".
    -- no `provider`: setup() falls back to the free keyless default.
    debounce_ms = 250,
    dismiss_threshold = 2,
    keys = { confirm = "<C-a>", }, -- PTY-sendable confirm key (see tests.md)
  }, overrides or {}))

  vim.keymap.set("v", "<leader>le", function()
    require("learning").explain()
  end, { desc = "[L]earning [E]xplain", })

  vim.notify("[learning.nvim tests] keyless skill-stage config loaded")
end

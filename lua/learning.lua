local config = require("learning.config")
local ai     = require("learning.ai")
local store  = require("learning.store")
local diff   = require("learning.diff")
local utils  = require("learning.utils")
local window = require("learning.window")

local Learning = {
  enabled = true,

  augroup = vim.api.nvim_create_augroup("Learning", { clear = true, }),
}

-- the debounced auto-suggestion trigger. defined with the rest of the
-- pipeline at the bottom of the file, forward-declared so `setup` can stay
-- at the top where a reader lands first.
local schedule_suggestion

--- setup learning.nvim
---@param opts? learning.Config
function Learning.setup(opts)
  -- `eagerness` was replaced by automatic per-language skill-level progression
  -- (config.LEVELS + unlock_threshold). Warn rather than silently ignore it, as
  -- users often update without reading the breaking-change note.
  if opts and opts.eagerness ~= nil then
    vim.deprecate("require('learning').setup({ eagerness })",
      "automatic skill-level progression (remove the option; tune `unlock_threshold` instead)",
      "a future release", "learning.nvim", false)
  end

  config.options = vim.tbl_deep_extend("force", config.options, opts or {})

  if type(config.options.ignored_buffers) == "function" then
    config.options.ignored_buffers = config.options.ignored_buffers()
  end

  local provider = config.options.provider
  if provider.api_url == "" or provider.model == "" or provider.api_key == "" then
    vim.notify("[learning.nvim] provider api_url, model and api_key must be set",
      vim.log.levels.ERROR)
    return
  end

  -- snapshot the buffer on entry so the first edit has a baseline to diff against
  vim.api.nvim_create_autocmd("BufEnter", {
    group = Learning.augroup,
    callback = function()
      local buf = vim.api.nvim_get_current_buf()
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
        local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        vim.b.learning_old = content
        vim.b.learning_new = content
      end
    end,
  })

  -- run the (debounced) suggestion pipeline whenever the buffer changes
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP", "TextChanged", "InsertLeave", }, {
    group = Learning.augroup,
    callback = function()
      if Learning.enabled then schedule_suggestion() end
    end,
  })
end

--- shows the suggestion in a floating window, deciding what dismiss and accept
--- mean: dismissing an auto-suggestion may record a dismissal toward
--- suppression, and accepting a (valid) edit applies it to `toedit`.
---@param toedit integer buffer to apply the edit to
---@param suggestion learning.Suggestion
function Learning.show(toedit, suggestion)
  if not suggestion or not suggestion.summary then return end

  -- only offer "accept" when the model returned a well-formed replacement
  local edit = utils.valid_edit(suggestion.edit)

  -- a valid edit is shown as a red/green diff: the lines it would replace (still
  -- in the buffer at show-time) are "before", its content is "after". this makes
  -- the correction explicit, so the prose explanation never has to repeat it.
  local diff_view
  if edit and vim.api.nvim_buf_is_valid(toedit) and vim.api.nvim_buf_is_loaded(toedit) then
    diff_view = {
      before = vim.api.nvim_buf_get_lines(toedit, edit.start, edit.final, false),
      after = edit.content,
    }
  end

  -- engaging with an auto-suggestion (either accepting or dismissing it) counts
  -- toward unlocking the next skill level for this language.
  local function record_engagement()
    if suggestion.track_dismiss then
      store.record_interaction(suggestion.language, suggestion.level)
    end
  end

  window.show({
    summary = suggestion.summary,
    diff = diff_view,
    on_dismiss = function()
      record_engagement()
      -- only explicit dismissals of auto-suggestions count toward suppression;
      -- accepting an edit or replacing the window does not.
      if suggestion.track_dismiss then
        store.record_dismiss(suggestion.language, suggestion.feature)
      end
    end,
    on_accept = edit and function()
      record_engagement()
      -- guard against out-of-range indices from a malformed model edit
      local ok = pcall(vim.api.nvim_buf_set_lines, toedit, edit.start, edit.final, false, edit.content)
      if ok and vim.api.nvim_buf_is_valid(toedit) and vim.api.nvim_buf_is_loaded(toedit) then
        vim.b[toedit].learning_old = vim.api.nvim_buf_get_lines(toedit, 0, -1, false)
      end
    end or nil,
  })
end

--- explains the current visual selection on demand (`:Learning explain`)
function Learning.explain()
  local buf = vim.api.nvim_get_current_buf()
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then return end

  local lines = utils.visual_selection(buf)
  if not lines then
    vim.notify("[learning.nvim] no visual selection to explain", vim.log.levels.WARN)
    return
  end

  ai.explain(table.concat(lines, "\n"), vim.bo[buf].filetype, function(suggestion)
    if suggestion then Learning.show(buf, suggestion) end
  end)
end

function Learning.enable()
  Learning.enabled = true
end

function Learning.disable()
  Learning.enabled = false
end

function Learning.toggle()
  Learning.enabled = not Learning.enabled
end

-- auto-suggestion pipeline, driven by the autocmds registered in `setup`

--- diffs the current buffer against its last snapshot and runs the two-stage
--- cascade: a cheap stage-1 `classify` on every edit, then — only when the
--- deterministic gate (`store.should_teach`) passes — the heavier stage-2
--- `teach` that produces the shown suggestion. The `learning_pending` guard
--- spans both calls so the gated-out common path stays a single small request.
local function send_suggestion()
  if not Learning.enabled or not utils.should_suggest() then return end

  local buf = vim.api.nvim_get_current_buf()
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then return end

  -- one request at a time per buffer, to avoid stacking overlapping popups
  if vim.b.learning_pending then return end

  vim.b.learning_new = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if vim.b.learning_old == nil then
    vim.b.learning_old = vim.b.learning_new
    return
  end

  local change = diff.compute(vim.b.learning_old, vim.b.learning_new)
  if not change then return end

  local filetype = vim.bo[buf].filetype

  -- settle the in-flight guard exactly once, whichever stage the cascade ends on
  vim.b.learning_pending = true
  local function settle()
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
      vim.b[buf].learning_pending = false
      vim.b[buf].learning_old = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
  end

  ai.classify(change, filetype, function(classification)
    if not classification then return settle() end
    local language = classification.language
    -- deterministic gate: skip stage 2 for nothing-to-teach / suppressed / locked
    if not store.should_teach(language, classification.level, classification.feature) then
      return settle()
    end

    ai.teach(change, filetype, classification.feature, function(suggestion)
      settle()
      if not suggestion then return end
      suggestion.feature = classification.feature
      suggestion.language = language
      suggestion.level = classification.level
      suggestion.track_dismiss = true
      Learning.show(buf, suggestion)
    end)
  end)
end

local debounce_timer

--- debounces `send_suggestion` so a burst of edits triggers a single request
function schedule_suggestion()
  if debounce_timer then
    debounce_timer:stop()
  end

  local timer = vim.uv.new_timer()
  if not timer then return end
  debounce_timer = timer

  timer:start(config.options.debounce_ms, 0, vim.schedule_wrap(function()
    if debounce_timer ~= timer then return end
    debounce_timer = nil
    send_suggestion()
  end))
end

return Learning

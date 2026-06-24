local config = require("learning.config")
local ai     = require("learning.ai")
local store  = require("learning.store")
local diff   = require("learning.diff")
local utils  = require("learning.utils")
local window = require("learning.window")
local drill  = require("learning.drill")

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
  ---@diagnostic disable-next-line: undefined-field
  if opts and opts.eagerness ~= nil then -- intentionally not in learning.Config
    vim.deprecate("require('learning').setup({ eagerness })",
      "automatic skill-level progression (remove the option; tune `unlock_threshold` instead)",
      "a future release", "learning.nvim", false)
  end

  -- the flat `keys.confirm/dismiss` became grouped keys (suggestion vs drilling)
  -- when the active-recall drill landed; warn rather than silently ignore them.
  ---@diagnostic disable-next-line: undefined-field
  if opts and opts.keys and (opts.keys.confirm ~= nil or opts.keys.dismiss ~= nil) then
    vim.deprecate("require('learning').setup({ keys = { confirm/dismiss } })",
      "grouped keys.suggestion.{learn,dismiss} and keys.drilling.{submit,give_up,dismiss}",
      "a future release", "learning.nvim", false)
  end

  -- grab the user's provider (if any) BEFORE the deep-merge: it must REPLACE the
  -- default verbatim, never merge into it. the default is the free fallback, whose
  -- blank Authorization header would otherwise deep-merge onto a real provider that
  -- omits `headers` and silently blank its auth.
  local user_provider = opts and opts.provider

  config.options = vim.tbl_deep_extend("force", config.options, opts or {})

  if type(config.options.ignored_buffers) == "function" then
    config.options.ignored_buffers = config.options.ignored_buffers()
  end

  -- without a configured provider, keep the free keyless default so the plugin
  -- works out of the box — warn (not error) so the user knows to configure their
  -- own for better results. with one, take it as-is (verbatim, see above).
  if user_provider then
    config.options.provider = user_provider
  else
    vim.notify("[learning.nvim] no provider configured — using the free OpenCode Zen "
      .. "provider. Set `provider` in setup() to use your own model for better results.",
      vim.log.levels.WARN)
  end

  -- apply configured highlight groups (e.g. LearningSpinner)
  for group, spec in pairs(config.options.highlights or {}) do
    if type(spec) == "string" then
      pcall(vim.api.nvim_set_hl, 0, group, { link = spec, })
    elseif type(spec) == "table" then
      pcall(vim.api.nvim_set_hl, 0, group, spec)
    end
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

--- builds the action list for a focused suggestion/reminder window: an optional
--- learn/re-learn action (opens a drill) followed by dismiss. read live so a
--- `setup` keymap change is honored.
---@param on_learn? fun() runs the learn/re-learn action; omit for dismiss-only
---@param learn_label? string winbar label for that action ("learn" / "re-learn")
---@param on_dismiss fun() runs on dismiss
---@return learning.Window.Action[]
local function suggestion_actions(on_learn, learn_label, on_dismiss)
  local k = config.options.keys.suggestion
  local actions = { { key = k.dismiss, fn = on_dismiss, label = "dismiss", }, }
  if on_learn then
    table.insert(actions, 1, { key = k.learn, fn = on_learn, label = learn_label, })
  end
  return actions
end

--- the user's progress toward mastery (the top tier) in a language, as 0..1.
---@param p table a `store.progress_summary` result
---@return number
local function mastery_fraction(p)
  if p.at_max then return 1 end
  return ((p.level_index - 1) + math.min(p.known_at_tier / p.threshold, 1)) / (#config.LEVELS - 1)
end

--- a compact progress bar toward mastering `language`, for a window footer.
---@param language string
---@return string
local function progress_footer(language)
  local p = store.progress_summary(language)
  return string.format(" %s %s ", p.level, utils.bar(mastery_fraction(p), 12))
end

--- shows a teach suggestion: the explanation only — the rewrite is *withheld* so
--- the learner reconstructs it in a drill. `learn` opens the drill on the feature;
--- `dismiss` records a dismissal toward suppression. with no usable edit to anchor
--- a drill it degrades to a dismiss-only note.
---@param buf integer
---@param filetype string
---@param feature string
---@param suggestion learning.Suggestion
function Learning.show_suggestion(buf, filetype, feature, suggestion)
  if not suggestion or not suggestion.summary then return end
  local edit = utils.valid_edit(suggestion.edit)

  local function on_dismiss() store.record_dismiss(filetype, feature) end
  local on_learn = edit and function()
    drill.start(buf, { feature = feature, edit = edit, filetype = filetype, })
  end or nil

  window.show({
    summary = suggestion.summary,
    actions = suggestion_actions(on_learn, "learn", on_dismiss),
    footer = progress_footer(filetype),
  })
end

--- shows a reminder for a feature the user already knows but slipped on: a short
--- nudge (a fenced snippet is fine here). `re-learn` re-runs teach and drops into a
--- drill; `dismiss` records a dismissal.
---@param buf integer
---@param change learning.Diff
---@param filetype string
---@param feature string
---@param text string
function Learning.show_reminder(buf, change, filetype, feature, text)
  local function on_dismiss() store.record_dismiss(filetype, feature) end
  local function on_relearn()
    ai.teach(change, filetype, feature, function(suggestion)
      local edit = suggestion and utils.valid_edit(suggestion.edit)
      if edit then drill.start(buf, { feature = feature, edit = edit, filetype = filetype, }) end
    end)
  end

  window.show({
    summary = text,
    actions = suggestion_actions(on_relearn, "re-learn", on_dismiss),
    footer = progress_footer(filetype),
  })
end

--- explains the current visual selection on demand (`:Learning explain`). a plain,
--- dismiss-only note — no drill, no dismissal recorded.
function Learning.explain()
  local buf = vim.api.nvim_get_current_buf()
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then return end

  local lines = utils.visual_selection(buf)
  if not lines then
    vim.notify("[learning.nvim] no visual selection to explain", vim.log.levels.WARN)
    return
  end

  utils.show_spinner()
  ai.explain(table.concat(lines, "\n"), vim.bo[buf].filetype, function(suggestion)
    utils.hide_spinner()
    if not (suggestion and suggestion.summary) then return end
    window.show({
      summary = suggestion.summary,
      actions = suggestion_actions(nil, nil, function() end),
    })
  end)
end

--- shows the user's learning progress (`:Learning progress`): the current buffer's
--- language first — its tier, a mastery bar, and the features learned in it — then
--- a bar for every other language touched.
function Learning.progress()
  local current = vim.bo[vim.api.nvim_get_current_buf()].filetype
  local lines = {}

  local function block(lang, detailed)
    local p = store.progress_summary(lang)
    table.insert(lines, string.format("%s  %-12s %s", utils.bar(mastery_fraction(p), 16), p.level, lang))
    if not detailed then return end
    if p.at_max then
      table.insert(lines, "  mastered — keep using advanced features")
    else
      table.insert(lines, string.format("  %d/%d features known toward %s",
        p.known_at_tier, p.threshold, config.LEVELS[p.level_index + 1]))
    end
    for _, k in ipairs(p.known) do
      table.insert(lines, string.format("    • %s (%s)", k.feature, k.level))
    end
  end

  if current ~= "" then
    table.insert(lines, "# " .. current)
    block(current, true)
    table.insert(lines, "")
  end

  local others = {}
  for _, lang in ipairs(store.languages()) do
    if lang ~= current then table.insert(others, lang) end
  end
  if #others > 0 then
    table.insert(lines, "# other languages")
    for _, lang in ipairs(others) do block(lang, false) end
  end

  if #lines == 0 then lines = { "no progress recorded yet — start coding!", } end

  window.show({
    summary = table.concat(lines, "\n"),
    actions = suggestion_actions(nil, nil, function() end),
  })
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
--- cascade: a cheap stage-1 `evaluate` on every edit — which both records what the
--- edit shows the user already knows (advancing their inferred level) and names
--- what it misses — then, only when the deterministic gate (`store.should_teach`)
--- passes, the heavier stage-2 `teach` that produces the shown suggestion. The
--- `learning_pending` guard spans both calls so the gated-out path stays small.
local function send_suggestion()
  if not Learning.enabled or not utils.should_suggest() then return end

  local buf = vim.api.nvim_get_current_buf()
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then return end

  -- one request at a time per buffer, to avoid stacking overlapping popups
  if vim.b.learning_pending then return end

  -- stand down entirely while a drill is open for this buffer
  if drill.active(buf) then return end

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

  ai.evaluate(change, filetype, function(evaluation)
    if not evaluation then return settle() end

    -- record what the edit DEMONSTRATED first: this may raise the user's level
    -- enough that a feature missed in the SAME edit now clears the gate.
    store.record_knowledge(filetype, evaluation.already_knows)

    -- deterministic gate: skip stage 2 for nothing-to-teach / suppressed / locked
    local need = evaluation.need_to_learn
    if not store.should_teach(filetype, need.level, need.feature) then
      return settle()
    end

    -- phase 1 cleared the gate: we're committing to a stage-2 request that will
    -- open a window. tell the user what's coming and show the loading spinner
    -- while the heavier teach/remind request is in flight.
    vim.notify("[learning.nvim] is going to teach you about `" .. need.feature .. "`")
    utils.show_spinner()

    -- a feature the user has demonstrably known (used >= know_threshold times) is a
    -- slip, not a gap: nudge with a reminder. otherwise teach it and offer a drill.
    if store.is_known(filetype, need.feature) then
      ai.remind(change, filetype, need.feature, function(reminder)
        utils.hide_spinner()
        settle()
        if reminder then
          Learning.show_reminder(buf, change, filetype, need.feature, reminder.summary)
        end
      end)
    else
      ai.teach(change, filetype, need.feature, function(suggestion)
        utils.hide_spinner()
        settle()
        if suggestion then Learning.show_suggestion(buf, filetype, need.feature, suggestion) end
      end)
    end
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

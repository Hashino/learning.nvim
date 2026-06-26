local config  = require("learning.config")
local ai      = require("learning.ai")
local utils   = require("learning.utils")
local window  = require("learning.window")
local Session = require("learning.teach_session")

---@class learning.Drill [Hashino/learning.nvim] the live active-recall drill: it
--- owns everything the pure `teach_session` state machine cannot — the code-buffer
--- edits (comment the lines, restore on give-up), the cursor, the example HUD, the
--- code-buffer keymaps, and the `ai.verify`/`ai.gen_example` calls — and performs
--- whatever action the session returns. one drill per buffer at a time.
local Drill = {}

-- per-buffer live drill state. shape:
-- { session, snapshot, feature, filetype, ns, m_start, m_end, comment_start,
--   comment_count, explanation, timer, original, examples, solution, last_code,
--   want, checking, verify_token }
-- examples: per-phase prefetched { explanation, code } (generated up front from
-- `original`); want: the phase to render as soon as its prefetch lands; solution:
-- the canonical rewrite (the solution example's code), shown last and handed to
-- verify as a reference; checking/verify_token: in-flight-submit guard.
local sessions = {}

local INSTRUCTION =
  "**learning mode** — reimplement the commented-out code below using what's shown."

--- whether a drill is currently open for `buf` (so the suggestion pipeline can
--- stand down while the learner practises).
---@param buf integer
---@return boolean
function Drill.active(buf)
  return sessions[buf] ~= nil
end

--- comments the buffer lines `[start, final)` in place (via 'commentstring',
--- falling back to a bare `# `), so the learner keeps their original logic visible
--- as a reference while they rewrite it.
---@param buf integer
---@param start integer
---@param final integer
local function comment_lines(buf, start, final)
  local cs = vim.bo[buf].commentstring
  if cs == nil or cs == "" then cs = "# %s" end
  local old = vim.api.nvim_buf_get_lines(buf, start, final, false)
  local out = {}
  for _, l in ipairs(old) do
    table.insert(out, (cs:gsub("%%s", function() return l end)))
  end
  vim.api.nvim_buf_set_lines(buf, start, final, false, out)
end

--- the learner's current attempt — the lines between the two tracking extmarks.
---@param sess table
---@return string[]
local function attempt_lines(sess)
  local s = vim.api.nvim_buf_get_extmark_by_id(sess.buf, sess.ns, sess.m_start, {})
  local e = vim.api.nvim_buf_get_extmark_by_id(sess.buf, sess.ns, sess.m_end, {})
  if not s[1] or not e[1] or e[1] <= s[1] then return {} end
  return vim.api.nvim_buf_get_lines(sess.buf, s[1], e[1], false)
end

--- tears the drill down: stop the timer, clear keymaps + extmarks, close the HUD,
--- and re-baseline the suggestion pipeline's snapshot so the leftover edit doesn't
--- immediately re-trigger it.
---@param buf integer
local function cleanup(buf)
  local sess = sessions[buf]
  if not sess then return end
  if sess.timer then
    sess.timer:stop()
    if not sess.timer:is_closing() then sess.timer:close() end
  end
  local k = config.options.keys.drilling
  for _, lhs in ipairs({ k.submit, k.give_up, k.dismiss, }) do
    pcall(vim.keymap.del, "n", lhs, { buffer = buf, })
  end
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_clear_namespace, buf, sess.ns, 0, -1)
  end
  window.close()
  sessions[buf] = nil
  if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
    vim.b[buf].learning_old = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
end

--- renders the HUD (instruction + explanation + the current scaffold example) as a
--- passive, unfocused float so the cursor stays in the code buffer.
---@param sess table
---@param example learning.Example
local function show_hud(sess, example)
  sess.explanation = example.explanation or sess.explanation or ""
  -- retain the last real code shown, so a later dropped/empty example reuses it
  -- instead of blanking the fence (see escalate / the prefetch fallback).
  if example.code and #example.code > 0 then sess.last_code = example.code end
  local body = { INSTRUCTION, "", sess.explanation, }
  local code = (example.code and #example.code > 0) and example.code or sess.last_code
  if code and #code > 0 then
    table.insert(body, "")
    table.insert(body, "```" .. sess.filetype)
    vim.list_extend(body, code)
    table.insert(body, "```")
  end
  local k = config.options.keys.drilling
  window.show({
    summary = table.concat(body, "\n"),
    focus = false,
    winbar = string.format(" [learning.nvim] %s submit | %s give up | %s keep & stop",
      k.submit, k.give_up, k.dismiss),
  })
end

--- (re)starts the inactivity timer; an untouched drill auto-closes (leaving the
--- learner's work) after `drill_timeout_ms`.
---@param buf integer
local function arm_timer(buf)
  local sess = sessions[buf]
  if not sess then return end
  if sess.timer then sess.timer:stop() end
  sess.timer = sess.timer or vim.uv.new_timer()
  if not sess.timer then return end
  sess.timer:start(config.options.drill_timeout_ms, 0, vim.schedule_wrap(function()
    if sessions[buf] and sessions[buf].session:is_active() then cleanup(buf) end
  end))
end

--- shows the example for `phase` after a failed submit: instantly if its prefetch
--- (fired in Drill.start) has landed, otherwise the spinner until it does — the
--- prefetch callback renders it on arrival. no-op if the drill ended first.
---@param buf integer
---@param phase string
local function escalate(buf, phase)
  local sess = sessions[buf]
  if not sess then return end
  local ready = sess.examples[phase]
  if ready then
    utils.hide_spinner()
    sess.want = nil
    show_hud(sess, ready)
  else
    -- prefetch still in flight: keep the previous example up under a spinner and
    -- let the in-flight callback render this phase when it returns.
    sess.want = phase
    utils.show_spinner()
  end
end

--- the learner asked to be checked: verify their attempt, then act on the verdict.
--- a verify already in flight (slow provider) isn't ignored — the learner is asked,
--- natively, whether to cancel it and submit this newer answer instead. each submit
--- carries a token so a superseded verify's late result is dropped.
---@param buf integer
function Drill.submit(buf)
  local sess = sessions[buf]
  if not sess or not sess.session:is_active() then return end

  if sess.checking then
    local choice = vim.fn.confirm(
      "[learning.nvim] a check is still running. submit this answer instead?",
      "&Submit new\n&Wait", 1)
    if choice ~= 1 then return end -- keep waiting on the in-flight check
  end

  if sess.session:submit().kind ~= "verify" then return end
  arm_timer(buf)

  sess.checking = true
  sess.verify_token = (sess.verify_token or 0) + 1
  local token = sess.verify_token
  local code = table.concat(attempt_lines(sess), "\n")
  local ctx = {
    original = sess.original,
    solution = sess.solution and table.concat(sess.solution, "\n") or nil,
  }
  ai.verify(code, sess.filetype, sess.feature, ctx, function(ok, hint)
    local s = sessions[buf]
    if not s or s.verify_token ~= token then return end -- torn down or superseded
    s.checking = false
    local action = s.session:result(ok)
    if action.kind == "mastered" then
      -- drop the commented reference, keep the learner's idiomatic code
      pcall(vim.api.nvim_buf_set_lines, buf, s.comment_start,
        s.comment_start + s.comment_count, false, {})
      cleanup(buf)
      vim.notify("[learning.nvim] you learned `" .. s.feature .. "`",
        vim.log.levels.INFO)
    elseif action.kind == "example" then
      -- wrong, and the scaffold is escalating to a closer example (usually already
      -- prefetched, so the swap is instant).
      vim.notify(hint and ("[learning.nvim] incorrect answer: " .. hint)
        or "[learning.nvim] incorrect — here is a closer example", vim.log.levels.WARN)
      escalate(buf, action.phase)
    elseif action.kind == "retry" then
      vim.notify(hint and ("[learning.nvim] incorrect answer: " .. hint)
        or "[learning.nvim] incorrect answer: try again", vim.log.levels.INFO)
    end
  end)
end

--- the learner gave up: restore their original code and tear down.
---@param buf integer
function Drill.give_up(buf)
  local sess = sessions[buf]
  if not sess or not sess.session:is_active() then return end
  if sess.session:give_up().kind == "restore" then
    pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, sess.snapshot)
  end
  cleanup(buf)
end

--- the learner is done but wants to keep what they wrote: tear down, touch nothing.
---@param buf integer
function Drill.dismiss(buf)
  local sess = sessions[buf]
  if not sess or not sess.session:is_active() then return end
  sess.session:dismiss()
  cleanup(buf)
end

--- opens a drill for `feature` on `buf`: comments the lines the lesson is about
--- (the diff's changed range), opens a fresh line below for the learner, seeds the
--- HUD with the suggestion's explanation, binds the drill keys, and prefetches all
--- three scaffold rungs from the original code so escalation feels instant.
---@param buf integer
---@param opts { feature: string, filetype: string, range: { start: integer, final: integer }, explanation?: string }
function Drill.start(buf, opts)
  if sessions[buf] or not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then
    return
  end

  local range = opts.range
  local line_count = vim.api.nvim_buf_line_count(buf)
  local start = math.max(0, math.min(range.start, line_count))
  local final = math.max(start, math.min(range.final, line_count))
  if final <= start then return end -- nothing to anchor the drill to

  local snapshot = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  comment_lines(buf, start, final)
  vim.api.nvim_buf_set_lines(buf, final, final, false, { "", }) -- a fresh line to work on

  local ns = vim.api.nvim_create_namespace("learning.drill")
  local m_start = vim.api.nvim_buf_set_extmark(buf, ns, final, 0, { right_gravity = false, })
  local m_end = vim.api.nvim_buf_set_extmark(buf, ns, final + 1, 0, { right_gravity = true, })

  -- the original (now-commented) lines: every rung is generated from these fixed
  -- inputs, so all three can be prefetched at once with no dependency on the
  -- learner's evolving attempt (only verify reads that).
  local original = {}
  for i = start + 1, final do original[#original + 1] = snapshot[i] end
  local original_code = table.concat(original, "\n")

  local sess = {
    buf = buf,
    session = Session.new(opts.feature, config.options.drill_related_after,
      config.options.drill_solution_after),
    snapshot = snapshot,
    feature = opts.feature,
    filetype = opts.filetype,
    ns = ns,
    m_start = m_start,
    m_end = m_end,
    comment_start = start,
    comment_count = final - start,
    explanation = opts.explanation or "",
    original = original_code,
    examples = {},
    want = "analogous", -- render the first rung as soon as its prefetch lands
  }
  sessions[buf] = sess

  -- bind the drill keys on the CODE buffer (the learner edits here, not the HUD)
  local k = config.options.keys.drilling
  vim.keymap.set("n", k.submit, function() Drill.submit(buf) end, { buffer = buf, })
  vim.keymap.set("n", k.give_up, function() Drill.give_up(buf) end, { buffer = buf, })
  vim.keymap.set("n", k.dismiss, function() Drill.dismiss(buf) end, { buffer = buf, })

  pcall(vim.api.nvim_win_set_cursor, 0, { final + 1, 0, })
  arm_timer(buf)

  -- show the explanation immediately so the HUD never opens blank; the example
  -- fills in when the analogous prefetch lands (see `want`).
  show_hud(sess, { explanation = sess.explanation, })

  -- prefetch all three rungs concurrently. each callback is guarded by session
  -- identity, so a straggler returning after teardown (or a new drill on the same
  -- buffer) is a no-op. the solution rung's code is the canonical answer: shown
  -- last and handed to verify as a reference.
  for _, phase in ipairs({ "analogous", "related", "solution", }) do
    ai.gen_example(opts.feature, opts.filetype, phase, original_code, function(example)
      if sessions[buf] ~= sess then return end
      if example then
        sess.examples[phase] = example
        if phase == "solution" then sess.solution = example.code end
      end
      if sess.want == phase then
        utils.hide_spinner()
        sess.want = nil
        show_hud(sess, example or { explanation = sess.explanation, code = sess.last_code, })
      end
    end)
  end
end

return Drill

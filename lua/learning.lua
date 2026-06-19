local config   = require("learning.config")
local ai       = require("learning.ai")
local store    = require("learning.store")

local Learning = {
  win_id = nil,
  enabled = true,
  debounce_timer = nil,

  augroup = vim.api.nvim_create_augroup("Learning", { clear = true, }),
}

--- trims and drops blank lines, so two regions can be compared ignoring
--- pure indentation / blank-line churn.
---@param lines string[]
---@return string[]
local function meaningful(lines)
  local out = {}
  for _, l in ipairs(lines) do
    local t = vim.trim(l)
    if t ~= "" then table.insert(out, t) end
  end
  return out
end

--- true when a change isn't worth teaching about: a pure deletion, a
--- whitespace/blank-line only change, or a re-indent (same text, new spacing).
---@param old_changed string[] the old lines that actually changed
---@param new_changed string[] the new lines that actually changed
---@return boolean
local function is_trivial(old_changed, new_changed)
  local new_m = meaningful(new_changed)
  -- nothing of substance was added (pure deletion / blank lines / whitespace)
  if #new_m == 0 then return true end
  -- identical once whitespace is ignored: only indentation/spacing changed
  return vim.deep_equal(new_m, meaningful(old_changed))
end

--- computes the changed region between two buffer snapshots using real diff
--- hunks (not a positional line-by-line compare, which falsely flags every
--- line below an insertion/deletion as "changed").
---@param old string[]
---@param new string[]
---@return learning.Diff|nil
local function compute_diff(old, new)
  local hunks = vim.diff(
    table.concat(old, "\n"), table.concat(new, "\n"),
    { result_type = "indices", }
  )
  ---@cast hunks integer[][]|nil
  if not hunks or #hunks == 0 then return nil end

  -- union of the changed line ranges, in old- and new-buffer coordinates
  local new_min, new_max = math.huge, 0
  local old_min, old_max = math.huge, 0
  local old_changed, new_changed = {}, {}

  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    -- count == 0 marks an insertion/deletion point; anchor on the hunk start
    old_min = math.min(old_min, sa)
    old_max = math.max(old_max, ca > 0 and sa + ca - 1 or sa)
    new_min = math.min(new_min, sb)
    new_max = math.max(new_max, cb > 0 and sb + cb - 1 or sb)

    if ca > 0 then vim.list_extend(old_changed, vim.list_slice(old, sa, sa + ca - 1)) end
    if cb > 0 then vim.list_extend(new_changed, vim.list_slice(new, sb, sb + cb - 1)) end
  end

  if is_trivial(old_changed, new_changed) then return nil end

  local context = 10
  local from = math.max(1, new_min - context)
  local to = math.min(#new, new_max + context)
  local old_from = math.max(1, old_min - context)
  local old_to = math.min(#old, old_max + context)

  return {
    start = from - 1,
    old_content = vim.list_slice(old, old_from, old_to),
    new_content = vim.list_slice(new, from, to),
  }
end

-- buftypes that never make sense to suggest on
local ignored_buftypes = {
  popup = true,
  prompt = true,
  terminal = true,
  help = true,
  nofile = true,
}

--- checks whether the current buffer should receive suggestions
---@return boolean
local function should_suggest()
  -- once a buffer gets checked once, a variable is set to avoid
  -- redoing the checking on every update
  if vim.b.learning_should_suggest ~= nil then
    return vim.b.learning_should_suggest
  end

  -- only suggest on normal buffers
  if ignored_buftypes[vim.bo.buftype] or vim.fn.win_gettype() ~= "" then
    vim.b.learning_should_suggest = false
    return false
  end

  ---@diagnostic disable-next-line: param-type-mismatch
  for _, exclude in ipairs(config.options.ignored_buffers) do
    if
        vim.bo.filetype:find(exclude)      -- match filetype
        or exclude == vim.fn.expand("%")   -- match filename
        or exclude == vim.fn.expand("%:p") -- match filepath
    then
      vim.b.learning_should_suggest = false
      return false
    end
  end

  vim.b.learning_should_suggest = true
  return true
end

local function send_suggestion()
  if not Learning.enabled then return end
  if not should_suggest() then return end

  local buf = vim.api.nvim_get_current_buf()
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then
    return
  end

  -- avoid stacking overlapping requests (and the duplicate popups they cause)
  -- while one is already in flight for this buffer.
  if vim.b.learning_pending then return end

  vim.b.learning_new = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  if vim.b.learning_old == nil then
    vim.b.learning_old = vim.b.learning_new
    return
  end

  local diff = compute_diff(vim.b.learning_old, vim.b.learning_new)
  if not diff then return end

  local filetype = vim.bo[buf].filetype
  local suppressed = store.suppressed_features(filetype)

  vim.b.learning_pending = true
  ai.suggestion(diff, filetype, suppressed, function(suggestion)
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
      vim.b[buf].learning_pending = false
      vim.b[buf].learning_old = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
    if not suggestion then return end
    -- enforce suppression client-side even if the model ignored the hint
    if store.is_suppressed(suggestion.language or filetype, suggestion.feature) then return end
    if config.options.eagerness > 0 and (suggestion.importance or 0) >= 1 - config.options.eagerness then
      suggestion.track_dismiss = true
      Learning.show(buf, suggestion)
    end
  end)
end

local function debounce()
  if Learning.debounce_timer then
    ---@diagnostic disable-next-line: undefined-field
    Learning.debounce_timer:stop()
  end
  local timer = vim.loop.new_timer()
  if not timer then return end
  Learning.debounce_timer = timer
  timer:start(config.options.debounce_ms, 0, vim.schedule_wrap(function()
    if Learning.debounce_timer ~= timer then return end
    Learning.debounce_timer = nil
    send_suggestion()
  end))
end

--- setup learning.nvim
---@param opts? learning.Config
function Learning.setup(opts)
  config.options = vim.tbl_deep_extend("force", config.options, opts or {})

  if type(config.options.ignored_buffers) == "function" then
    config.options.ignored_buffers = config.options.ignored_buffers()
  end

  if config.options.provider.api_url == ""
      or config.options.provider.model == ""
      or config.options.provider.api_key == "" then
    vim.notify("[learning.nvim] provider api_url, model and api_key must be set",
      vim.log.levels.ERROR)
    return
  end

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

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP", "TextChanged", "InsertLeave", }, {
    group = Learning.augroup,
    callback = function()
      if Learning.enabled then
        debounce()
      end
    end,
  })
end

--- shows a floating window with the suggestion summary and option to apply it
---@param toedit integer buffer to apply the edit to
---@param suggestion learning.Suggestion
function Learning.show(toedit, suggestion)
  if not suggestion or not suggestion.summary then
    return
  end

  if Learning.win_id then
    pcall(vim.api.nvim_win_close, Learning.win_id, true)
    Learning.win_id = nil
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local summary_lines = vim.split(suggestion.summary, "\n", { plain = true, })

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, summary_lines)

  -- TODO: use treesitter highlighting once the markdown codeblock crash is fixed
  -- https://github.com/nvim-treesitter/nvim-treesitter/issues/...
  vim.api.nvim_set_option_value("syntax", "markdown", { buf = buf, })

  vim.keymap.set("n", config.options.keys.dismiss, function()
    -- only explicit dismissals of auto-suggestions count toward suppression;
    -- accepting an edit or replacing the window does not.
    if suggestion.track_dismiss then
      store.record_dismiss(suggestion.language, suggestion.feature)
    end
    pcall(vim.api.nvim_win_close, Learning.win_id, true)
    Learning.win_id = nil
  end, { buffer = buf, })

  Learning.win_id = vim.api.nvim_open_win(buf, true, config.options.win_config)

  -- only offer "accept" when the model returned a well-formed replacement
  local edit = suggestion.edit
  local has_edit = type(edit) == "table"
      and type(edit.start) == "number"
      and type(edit.final) == "number"
      and type(edit.content) == "table"

  if has_edit then
    vim.keymap.set("n", config.options.keys.confirm, function()
      -- guard against out-of-range indices from a malformed model edit
      local ok = pcall(vim.api.nvim_buf_set_lines, toedit, edit.start, edit.final, false, edit.content)
      if ok and vim.api.nvim_buf_is_valid(toedit) and vim.api.nvim_buf_is_loaded(toedit) then
        vim.b[toedit].learning_old = vim.api.nvim_buf_get_lines(toedit, 0, -1, false)
      end
      pcall(vim.api.nvim_win_close, Learning.win_id, true)
      Learning.win_id = nil
    end, { buffer = buf, })

    vim.api.nvim_set_option_value("winbar",
      string.format(" [Learning] %s to accept | %s to dismiss",
        config.options.keys.confirm, config.options.keys.dismiss),
      { win = Learning.win_id, })
  else
    vim.api.nvim_set_option_value("winbar",
      string.format(" [Learning] %s to dismiss", config.options.keys.dismiss),
      { win = Learning.win_id, })
  end
end

function Learning.explain()
  -- visualmode() returns "" (not nil) when no visual mode has been used yet
  local mode = vim.fn.visualmode()
  if mode == "" then
    vim.notify("[learning.nvim] No previous visual selection", vim.log.levels.WARN)
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then return end

  local start_pos = vim.api.nvim_buf_get_mark(buf, "<")
  local end_pos = vim.api.nvim_buf_get_mark(buf, ">")

  if start_pos[1] == 0 and end_pos[1] == 0 then
    local v_start = vim.fn.getpos("v")
    local v_end = vim.fn.getpos(".")
    start_pos = { v_start[2], v_start[3] - 1 }
    end_pos = { v_end[2], v_end[3] - 1 }
  end

  if mode == "V" then
    start_pos[2] = 0
  end

  if start_pos[1] > end_pos[1] or (start_pos[1] == end_pos[1] and start_pos[2] > end_pos[2]) then
    start_pos, end_pos = end_pos, start_pos
  end

  local lines = vim.api.nvim_buf_get_lines(buf, start_pos[1] - 1, end_pos[1], false)
  if #lines == 0 then
    vim.notify("[learning.nvim] No selection to explain", vim.log.levels.WARN)
    return
  end

  if mode == "v" or mode == "\22" then
    lines[1] = string.sub(lines[1], start_pos[2] + 1)
    if #lines == 1 then
      lines[#lines] = string.sub(lines[#lines], 1, end_pos[2] - start_pos[2])
    else
      lines[#lines] = string.sub(lines[#lines], 1, end_pos[2] + 1)
    end
  end

  local selection = table.concat(lines, "\n")
  local filetype = vim.bo[buf].filetype

  ai.explain(selection, filetype, function(suggestion)
    if suggestion then
      Learning.show(buf, suggestion)
    end
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

return Learning

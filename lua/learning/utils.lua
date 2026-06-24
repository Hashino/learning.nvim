local config = require("learning.config")

local Utils = {}

-- spinner state (internal). a single shared spinner: requests don't overlap per
-- buffer (the `learning_pending` guard), and explain is one-shot.
local spinner_win = nil ---@type integer?
local spinner_timer = nil
local spinner_idx = 1 ---@type integer

--- shows a braille spinner in the bottom-right corner while a request is in
--- flight. idempotent — a second call while one is already up is a no-op.
function Utils.show_spinner()
  if spinner_win and vim.api.nvim_win_is_valid(spinner_win) then return end

  local chars = config.options.spinner_characters or { "⣾", }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { chars[1], })

  spinner_win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = 1,
    height = 1,
    row = vim.o.lines - 3 - vim.o.cmdheight,
    col = vim.o.columns - 2,
    style = "minimal",
    noautocmd = true,
  })

  vim.api.nvim_set_option_value("winhl", "Normal:LearningSpinner", { win = spinner_win, })

  spinner_idx = 1
  spinner_timer = vim.uv.new_timer()
  if spinner_timer then
    spinner_timer:start(
      config.options.spinner_interval_ms,
      config.options.spinner_interval_ms,
      vim.schedule_wrap(function()
        if not spinner_win or not vim.api.nvim_win_is_valid(spinner_win) then return end
        spinner_idx = (spinner_idx % #chars) + 1
        local b = vim.api.nvim_win_get_buf(spinner_win)
        vim.api.nvim_buf_set_lines(b, 0, -1, false, { chars[spinner_idx], })
      end))
  end
end

--- hides and cleans up the spinner. idempotent.
function Utils.hide_spinner()
  if spinner_timer then
    spinner_timer:stop()
    spinner_timer:close()
    spinner_timer = nil
  end
  if spinner_win and vim.api.nvim_win_is_valid(spinner_win) then
    pcall(vim.api.nvim_win_close, spinner_win, true)
  end
  spinner_win = nil
end

-- buftypes that never make sense to suggest on
local ignored_buftypes = {
  popup = true,
  prompt = true,
  terminal = true,
  help = true,
  nofile = true,
}

--- whether the current buffer should receive auto-suggestions. caches the
--- decision per-buffer (like doing.nvim's should_display) so the check isn't
--- redone on every keystroke.
---@return boolean
function Utils.should_suggest()
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

--- validates a model-supplied edit, returning it only when it has the shape
--- `nvim_buf_set_lines` needs. returns nil for a missing or malformed edit.
---@param edit learning.Edit?
---@return learning.Edit?
function Utils.valid_edit(edit)
  if type(edit) == "table"
      and type(edit.start) == "number"
      and type(edit.final) == "number"
      and type(edit.content) == "table"
  then
    return edit
  end
  return nil
end

--- the lines of the last visual selection in `buf`, honoring the selection
--- mode (charwise / linewise / blockwise). returns nil when there's no
--- previous selection or it's empty.
---@param buf integer
---@return string[]?
function Utils.visual_selection(buf)
  -- visualmode() returns "" (not nil) when no visual mode has been used yet
  local mode = vim.fn.visualmode()
  if mode == "" then return nil end

  local start_pos = vim.api.nvim_buf_get_mark(buf, "<")
  local end_pos = vim.api.nvim_buf_get_mark(buf, ">")

  -- fall back to the live selection endpoints if the marks aren't set yet
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
  if #lines == 0 then return nil end

  -- trim the partial first/last lines for charwise and blockwise selections
  if mode == "v" or mode == "\22" then
    lines[1] = string.sub(lines[1], start_pos[2] + 1)
    if #lines == 1 then
      lines[#lines] = string.sub(lines[#lines], 1, end_pos[2] - start_pos[2])
    else
      lines[#lines] = string.sub(lines[#lines], 1, end_pos[2] + 1)
    end
  end

  return lines
end

--- position of a skill level in config.LEVELS (1-based), or nil if unknown.
---@param level string?
---@return integer?
function Utils.level_index(level)
  for i, l in ipairs(config.LEVELS) do
    if l == level then return i end
  end
  return nil
end

--- coerces a model-supplied skill level into a known value. an explicit "none"
--- (nothing worth teaching) is preserved; anything missing or unrecognized
--- degrades to the lowest level so a weak model never silences the plugin.
---@param raw any
---@return string "none" or one of config.LEVELS
function Utils.normalize_level(raw)
  local s = vim.trim(tostring(raw or ""):lower())
  if s == "none" then return "none" end
  if Utils.level_index(s) then return s end
  return config.LEVELS[1]
end

--- a unicode progress bar: `width` cells, a `fraction` (0..1) of them filled.
---@param fraction number
---@param width integer
---@return string
function Utils.bar(fraction, width)
  fraction = math.max(0, math.min(1, fraction or 0))
  local filled = math.floor(fraction * width + 0.5)
  return string.rep("▰", filled) .. string.rep("▱", width - filled)
end

return Utils

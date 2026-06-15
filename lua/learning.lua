local config   = require("learning.config")
local ai       = require("learning.ai")

local Learning = {
  win_id = nil,
  enabled = true,
  debounce_timer = nil,

  augroup = vim.api.nvim_create_augroup("Learning", { clear = true, }),
}

local function compute_diff(old, new)
  local start_line = math.huge
  local end_line = 0

  for i = 1, math.max(#old, #new) do
    if old[i] ~= new[i] then
      start_line = math.min(start_line, i)
      end_line = math.max(end_line, i)
    end
  end

  if start_line == math.huge then return nil end

  local context = 10
  local from = math.max(1, start_line - context)
  local to = math.min(#new, end_line + context)
  local old_from = math.max(1, start_line - context)
  local old_to = math.min(#old, end_line + context)

  return {
    start = from - 1,
    old_content = vim.list_slice(old, old_from, old_to),
    new_content = vim.list_slice(new, from, to),
  }
end

--- checks whether the current buffer should receive suggestions
---@return boolean
local function should_suggest()
  -- once a buffer gets checked once, a variable is set to avoid
  -- redoing the checking on every update
  if vim.b.learning_should_suggest ~= nil then
    return vim.b.learning_should_suggest
  end

  -- only suggest on normal buffers
  if vim.bo.buftype == "popup" or vim.bo.buftype == "prompt" or vim.fn.win_gettype() ~= "" then
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

  vim.b.learning_new = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  if vim.b.learning_old == nil then
    vim.b.learning_old = vim.b.learning_new
    return
  end

  local diff = compute_diff(vim.b.learning_old, vim.b.learning_new)
  if not diff then return end

  local filetype = vim.bo[buf].filetype

  ai.suggestion(diff, filetype, function(suggestion)
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
      vim.b[buf].learning_old = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
    if suggestion and 1 - (suggestion.importance or 0) >= config.options.eagerness then
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

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP", "TextChanged" }, {
    group = Learning.augroup,
    callback = function()
      if Learning.enabled then
        debounce()
      end
    end,
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
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
  if suggestion then
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
      pcall(vim.api.nvim_win_close, Learning.win_id, true)
      Learning.win_id = nil
    end, { buffer = buf, })

    Learning.win_id = vim.api.nvim_open_win(buf, true, config.options.win_config)

    if suggestion.edit then
      vim.keymap.set("n", config.options.keys.confirm, function()
        vim.api.nvim_buf_set_lines(toedit, suggestion.edit.start, suggestion.edit.final, false,
          suggestion.edit.content)
        if vim.api.nvim_buf_is_valid(toedit) and vim.api.nvim_buf_is_loaded(toedit) then
          vim.b[toedit].learning_old = vim.api.nvim_buf_get_lines(toedit, 0, -1, false)
        end
        pcall(vim.api.nvim_win_close, Learning.win_id, true)
        Learning.win_id = nil
      end, { buffer = buf, })

      vim.api.nvim_set_option_value("winbar",
        string.format(" %s to accept | %s to dismiss",
          config.options.keys.confirm, config.options.keys.dismiss),
        { win = Learning.win_id, })
    else
      vim.api.nvim_set_option_value("winbar",
        string.format(" %s to dismiss", config.options.keys.dismiss),
        { win = Learning.win_id, })
    end
  end
end

function Learning.explain()
  local mode = vim.fn.visualmode()
  if mode == nil then
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

  ai.explain(selection, function(explanation)
    if explanation then
      Learning.show(buf, { summary = explanation })
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

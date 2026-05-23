local config   = require("learning.config")
local ai       = require("learning.ai")

local Learning = {
  buf = {
    old = nil,
    new = nil,
  },

  win_id = nil,

  enabled = true,

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

  if start_line > #old then return nil end

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

--- setup learning.nvim
---@param opts? learning.Config
function Learning.setup(opts)
  config.options = vim.tbl_deep_extend("force", config.options, opts or {})

  if config.options.provider.api_url == ""
      or config.options.provider.model == ""
      or config.options.provider.api_key == "" then
    vim.notify("[learning.nvim] provider api_url, model and api_key must be set",
      vim.log.levels.ERROR)
    return
  end

  -- snapshot buffer content on enter so we can diff on InsertLeave
  vim.api.nvim_create_autocmd("BufEnter", {
    group = Learning.augroup,
    callback = function()
      local buf = vim.api.nvim_get_current_buf()
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
        Learning.buf.new = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      end
    end,
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = Learning.augroup,
    callback = function()
      if Learning.enabled then
        local buf = vim.api.nvim_get_current_buf()
        if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then
          return
        end

        Learning.buf.old = Learning.buf.new
        Learning.buf.new = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

        if Learning.buf.old == Learning.buf.new then return end

        local diff = compute_diff(Learning.buf.old, Learning.buf.new)
        if not diff then return end

        vim.schedule(function()
          ai.suggestion(diff, function(suggestion)
            if suggestion then
              Learning.show(vim.api.nvim_get_current_buf(), suggestion)
            end
          end)
        end)
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

  local start_pos = vim.api.nvim_buf_get_mark(0, "<")
  local end_pos = vim.api.nvim_buf_get_mark(0, ">")

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

  local lines = vim.api.nvim_buf_get_lines(0, start_pos[1] - 1, end_pos[1], false)
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
      Learning.show(vim.api.nvim_get_current_buf(), {
        summary = explanation,
      })
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

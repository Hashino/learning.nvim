local config   = require("learning.config")
local ai       = require("learning.ai")

local Learning = {
  buf = {
    old = nil,
    new = nil,
  },

  win = nil,
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

  if start_line > #old then
    return nil
  end

  local context = 3
  local from = math.max(1, start_line - context)
  local to = math.min(#new, end_line + context)

  return {
    start = from - 1,
    content = vim.list_slice(new, from, to),
  }
end

---@param opts LearningOptions
function Learning.setup(opts)
  config.options = vim.tbl_deep_extend("force", config.default_opts, opts or {})

  if config.options.provider.api_url == "" or config.options.provider.model == "" or config.options.provider.api_key then
    vim.notify("[learning.nvim] provider api_url, model must be set", vim.log.levels.ERROR)
    return
  end

  vim.api.nvim_create_autocmd("BufEnter", {
    callback = function()
      local buf = vim.api.nvim_get_current_buf()

      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
        Learning.buf.new = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      end
    end
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    callback = function()
      local buf = vim.api.nvim_get_current_buf()
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
        Learning.buf.old = Learning.buf.new
        Learning.buf.new = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

        if Learning.buf.old == Learning.buf.new then
          return
        end

        local diff = compute_diff(Learning.buf.old, Learning.buf.new)
        if not diff then
          return
        end

        vim.schedule(function()
          local function show_suggestion(suggestion)
            if suggestion then
              local toedit = vim.api.nvim_get_current_buf()
              Learning.show(toedit, suggestion)
            end
          end

          ai.suggestion(diff, show_suggestion)
        end)
      end
    end,
  })
end

---Shows a floating window with the summary of the edit and the option to apply it or dismiss it.
---@param suggestion LearningSuggestion
function Learning.show(toedit, suggestion)
  if Learning.win then
    Learning.win = vim.api.nvim_win_close(Learning.win, true)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, suggestion.summary)

  -- options of the buffer
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  vim.api.nvim_set_option_value('readonly', true, { buf = buf })
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = buf })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })
  vim.api.nvim_set_option_value('filetype', 'markdown', { buf = buf })


  vim.keymap.set("n", config.options.keys.confirm, function()
    vim.api.nvim_buf_set_lines(toedit, suggestion.edit.start, suggestion.edit.final, false,
      suggestion.edit.content)
  end, { buffer = buf, })

  vim.keymap.set("n", config.options.keys.dismiss, function()
    Learning.win = vim.api.nvim_win_close(Learning.win, true)
  end, { buffer = buf, })

  Learning.win = vim.api.nvim_open_win(buf, false, config.options.win_config)
end

return Learning

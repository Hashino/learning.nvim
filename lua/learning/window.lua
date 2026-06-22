local config = require("learning.config")

---@class learning.Window [Hashino/learning.nvim] floating suggestion window
local Window = {
  win_id = nil,
}

-- highlight namespace for the red/green edit diff lines
local NS = vim.api.nvim_create_namespace("learning.diff")

--- builds the buffer lines for an optional before/after edit diff followed by the
--- markdown summary, plus the (row, highlight) pairs to mark the diff lines.
--- old lines render red ("- "), new lines green ("+ "), git-diff style.
---@param summary string
---@param d? { before: string[], after: string[] }
---@return string[] lines, { [1]: integer, [2]: string }[] marks
local function build_lines(summary, d)
  local lines, marks = {}, {}
  if d then
    for _, l in ipairs(d.before) do
      table.insert(lines, "- " .. l)
      table.insert(marks, { #lines - 1, "DiffDelete", })
    end
    for _, l in ipairs(d.after) do
      table.insert(lines, "+ " .. l)
      table.insert(marks, { #lines - 1, "DiffAdd", })
    end
    if #lines > 0 then table.insert(lines, "") end -- separator before the prose
  end
  vim.list_extend(lines, vim.split(summary, "\n", { plain = true, }))
  return lines, marks
end

--- closes the suggestion window if it is open
function Window.close()
  if Window.win_id and vim.api.nvim_win_is_valid(Window.win_id) then
    pcall(vim.api.nvim_win_close, Window.win_id, true)
  end
  Window.win_id = nil
end

---@class learning.Window.Opts
---@field summary string markdown body to display
---@field diff? { before: string[], after: string[] } optional edit, shown as a red/green diff above the summary
---@field on_dismiss? fun() runs when the user dismisses, before the window closes
---@field on_accept? fun() runs when the user accepts; when nil the window is dismiss-only

--- opens the floating suggestion window showing `summary` (and, when `diff` is
--- given, the red/green edit diff above it), wiring the dismiss (and, when
--- `on_accept` is given, the accept) keymaps and the matching winbar. only
--- handles the window: the meaning of dismiss/accept is the caller's.
---@param opts learning.Window.Opts
function Window.show(opts)
  Window.close()

  local buf = vim.api.nvim_create_buf(false, true)
  local lines, marks = build_lines(opts.summary, opts.diff)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- TODO: use treesitter highlighting once the markdown codeblock crash is fixed
  vim.api.nvim_set_option_value("syntax", "markdown", { buf = buf, })

  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, NS, m[1], 0, { line_hl_group = m[2], })
  end

  vim.keymap.set("n", config.options.keys.dismiss, function()
    if opts.on_dismiss then opts.on_dismiss() end
    Window.close()
  end, { buffer = buf, })

  if opts.on_accept then
    vim.keymap.set("n", config.options.keys.confirm, function()
      opts.on_accept()
      Window.close()
    end, { buffer = buf, })
  end

  Window.win_id = vim.api.nvim_open_win(buf, true, config.options.win_config)

  local hint = opts.on_accept
      and string.format(" [Learning] %s to accept | %s to dismiss",
        config.options.keys.confirm, config.options.keys.dismiss)
      or string.format(" [Learning] %s to dismiss", config.options.keys.dismiss)
  vim.api.nvim_set_option_value("winbar", hint, { win = Window.win_id, })

  -- keep win_id accurate if the window is closed by other means
  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = buf,
    once = true,
    callback = function() Window.win_id = nil end,
  })
end

return Window

local config = require("learning.config")

---@class learning.Window [Hashino/learning.nvim] floating window for suggestions,
--- reminders, and the drill HUD. purely mechanical: the caller passes the content,
--- the winbar hint, whether to focus it, and (for focused windows) the actions to
--- bind — the *meaning* of each action stays in the core file.
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

--- closes the window if it is open
function Window.close()
  if Window.win_id and vim.api.nvim_win_is_valid(Window.win_id) then
    pcall(vim.api.nvim_win_close, Window.win_id, true)
  end
  Window.win_id = nil
end

---@class learning.Window.Action
---@field key string keymap (lhs) bound on the float buffer
---@field fn fun() runs when pressed (the window is closed first)
---@field label string shown in the winbar hint

---@class learning.Window.Opts
---@field summary string markdown body to display
---@field diff? { before: string[], after: string[] } optional edit, shown as a red/green diff above the body
---@field actions? learning.Window.Action[] keymaps bound on the (focused) float buffer; their labels build the winbar
---@field winbar? string explicit winbar hint (for a passive HUD whose keys live elsewhere); overrides one built from actions
---@field footer? string optional border footer (e.g. a progress bar)
---@field focus? boolean enter the window (default true)

--- opens the floating window. with `actions`, each is bound as a normal-mode
--- keymap on the float buffer (the window is closed *before* the action runs, so
--- an action may open the next window) and the winbar lists them. with an explicit
--- `winbar` and no actions it's a passive HUD — `focus = false` keeps the cursor
--- in the code buffer and the caller binds the keys there.
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

  for _, a in ipairs(opts.actions or {}) do
    vim.keymap.set("n", a.key, function()
      Window.close()
      a.fn()
    end, { buffer = buf, })
  end

  local focus = opts.focus ~= false
  local win_config = config.options.win_config
  if opts.footer then
    win_config = vim.tbl_extend("force", win_config, { footer = opts.footer, footer_pos = "center", })
  end
  Window.win_id = vim.api.nvim_open_win(buf, focus, win_config)

  local winbar = opts.winbar
  if not winbar and opts.actions then
    local parts = {}
    for _, a in ipairs(opts.actions) do
      table.insert(parts, a.key .. " " .. a.label)
    end
    winbar = " [learning.nvim] " .. table.concat(parts, " | ")
  end
  vim.api.nvim_set_option_value("winbar", winbar or " [learning.nvim]", { win = Window.win_id, })

  -- keep win_id accurate if the window is closed by other means
  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = buf,
    once = true,
    callback = function() Window.win_id = nil end,
  })
end

return Window

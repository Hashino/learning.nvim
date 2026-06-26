local Diff = {}

---@class learning.Diff
---@field start integer start line of the context block (0-indexed)
---@field old_content string[] content of the old lines
---@field new_content string[] content of the new lines
---@field change_start integer first changed line, 0-indexed (no context padding)
---@field change_final integer one past the last changed line, 0-indexed exclusive

-- how many unchanged lines around the change to send along as context
local CONTEXT = 10

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
--- line below an insertion/deletion as "changed"). returns nil when nothing
--- worth teaching about changed.
---@param old string[]
---@param new string[]
---@return learning.Diff|nil
function Diff.compute(old, new)
  local hunks = vim.text.diff(
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

  local from = math.max(1, new_min - CONTEXT)
  local to = math.min(#new, new_max + CONTEXT)
  local old_from = math.max(1, old_min - CONTEXT)
  local old_to = math.min(#old, old_max + CONTEXT)

  return {
    start = from - 1,
    old_content = vim.list_slice(old, old_from, old_to),
    new_content = vim.list_slice(new, from, to),
    -- the changed lines themselves (new-buffer coords), no context padding: this
    -- is the region the drill comments out, derived here instead of round-tripped
    -- through the model.
    change_start = new_min - 1,
    change_final = new_max,
  }
end

return Diff

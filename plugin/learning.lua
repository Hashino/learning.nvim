local learning = require("learning")

local do_cmds  = {
  ["explain"]  = learning.explain,
  ["progress"] = learning.progress,
  ["enable"]   = learning.enable,
  ["disable"]  = learning.disable,
  ["toggle"]   = learning.toggle,
}

-- sets up the `:Learning` command
vim.api.nvim_create_user_command("Learning", function(args)
  local cmd = args.args:sub(1, (args.args:find(" ") or (#args.args + 1)) - 1)

  if vim.tbl_contains(vim.tbl_keys(do_cmds), cmd) then
    -- pass the range count through so explain can distinguish a real `:'<,'>`
    -- invocation from a bare normal-mode one. the other commands ignore it.
    do_cmds[cmd]({ range = args.range, })
  else
    vim.notify("[learning.nvim] Invalid command: " .. cmd, vim.log.levels.ERROR)
  end
end, {
  range = true,
  nargs = "?",
  bang = true,
  complete = function(_, cmd_line)
    local params = vim.split(cmd_line, "%s+", { trimempty = true, })

    if #params == 1 then
      return vim.tbl_keys(do_cmds)
    end
  end,
})


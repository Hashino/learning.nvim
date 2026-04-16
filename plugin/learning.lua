local learning = require("learning")

local do_cmds  = {
  ["enable"] = function()
    learning.enabled = true
  end,
  ["disable"] = function()
    learning.enabled = false
  end,
  ["toggle"] = function()
    learning.enabled = not learning.enabled
  end,
}

-- sets up the `:Do` command
vim.api.nvim_create_user_command("Learning", function(args)
  local cmd = args.args:sub(1, (args.args:find(" ") or (#args.args + 1)) - 1)

  -- checks if first argument is a Do command
  if vim.tbl_contains(vim.tbl_keys(do_cmds), cmd) then
    do_cmds[cmd]()
  else -- otherwise, treat the the arguments as the task
    vim.notify("[learning.nvim] Invalid command: " .. cmd, vim.log.levels.ERROR)
  end
end, {
  nargs = "?",
  bang = true,
  -- sets up completion for the `:Do` command
  complete = function(_, cmd_line)
    local params = vim.split(cmd_line, "%s+", { trimempty = true, })

    if #params == 1 then
      return vim.tbl_keys(do_cmds)
    end
  end,
})

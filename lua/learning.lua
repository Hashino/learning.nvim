local config = require("learning.config")

local Learning = {}

---@param opts LearningOptions
function Learning.setup(opts)
  config.options = vim.tbl_deep_extend("force", config.default_opts, opts or {})
end

return Learning

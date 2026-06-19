-- DEVELOPMENT ONLY — eagerness = 0.5: shows medium-and-higher importance
-- suggestions (importance >= 0.5). See tests/tests.md (eagerness gating).
local TESTS = "/home/hashino/.local/share/nvim/site/pack/core/opt/learning.nvim/tests"
dofile(TESTS .. "/shared.lua")(0.5)

-- DEVELOPMENT ONLY — eagerness = 1: every suggestion is shown regardless of
-- importance (same as the default init.lua, named for symmetry in the eagerness
-- matrix). See tests/tests.md (eagerness gating).
local TESTS = "/home/hashino/.local/share/nvim/site/pack/core/opt/learning.nvim/tests"
dofile(TESTS .. "/shared.lua")(1)

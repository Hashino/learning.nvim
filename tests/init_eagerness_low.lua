-- DEVELOPMENT ONLY — eagerness = 0.1: only high-importance suggestions
-- (importance >= 0.9) are shown. See tests/tests.md (eagerness gating).
local TESTS = "/home/hashino/.local/share/nvim/site/pack/core/opt/learning.nvim/tests"
dofile(TESTS .. "/shared.lua")(0.1)

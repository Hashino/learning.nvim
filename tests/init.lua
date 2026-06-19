-- DEVELOPMENT ONLY — default keyless test config (eagerness = 1, shows every
-- suggestion). Used by every test step except the eagerness matrix, which has its
-- own per-level configs (init_eagerness_*.lua). See tests/tests.md.
local TESTS = "/home/hashino/.local/share/nvim/site/pack/core/opt/learning.nvim/tests"
dofile(TESTS .. "/shared.lua")(1)

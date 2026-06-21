-- DEVELOPMENT ONLY — default keyless test config. The user starts every language
-- at the "beginner" skill level and unlocks higher levels by engaging with
-- suggestions (no eagerness knob anymore). See tests/tests.md.
local TESTS = "/home/hashino/.local/share/nvim/site/pack/core/opt/learning.nvim/tests"
dofile(TESTS .. "/shared.lua")()

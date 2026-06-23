-- DEVELOPMENT ONLY — default keyless test config. The user starts every language
-- at the "beginner" skill level and unlocks higher levels by engaging with
-- suggestions (no eagerness knob anymore). See tests/tests.md.
-- this file's own directory, so the suite runs from any checkout / cwd
local TESTS = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
dofile(TESTS .. "/shared.lua")()

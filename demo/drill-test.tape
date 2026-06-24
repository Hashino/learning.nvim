Output drill-test.mp4

# A drill-only quality-check tape: the same obvious flow as the real demo.tape
# (type a non-idiomatic function -> get a suggestion -> learn -> reimplement it),
# but the FIRST submit is already the idiomatic answer, so the drill masters in
# one try. Use it to eyeball the drill UI (HUD, winbar, mastery notification)
# before paying for the long full demo.  TAPE=drill-test.tape ./demo/record.sh
#
# Recorded to MP4; record.sh converts it to a GIF with the same ffmpeg pass.
# These Set values are kept IDENTICAL to demo.tape so the look is representative.

Require nvim

Set FontSize 27
Set Width 1920
Set Height 1080
Set FontFamily "UbuntuMono Nerd Font"
Set Theme "nord"
Set Framerate 30
Set TypingSpeed 120ms
Set Padding 20
Set WindowBar "Colorful"
Set BorderRadius 12

# Open demo.c — it already contains one idiomatic function (sum). Wait for the
# file's own text instead of a fixed Sleep, so we reveal a fully-loaded editor.
Hide
Type "nvim -u init.lua demo.c"
Enter
Wait+Screen@30s /sum of all elements/
Show
Sleep 1s

# Jump to the end and add a SECOND function with a blatantly non-idiomatic
# pattern: an if-guard picking one of two values, where a ternary says it all.
# Returning two *non-boolean* values means the ternary is the ONLY idiomatic
# rewrite, so the model reliably teaches that one thing. Leading spaces are
# omitted — Neovim auto-indents after `{`.
Type "G"
Sleep 500ms
Type "o"
Sleep 200ms
Enter
Type "// returns the larger of a and b"
Enter
Type "int larger(int a, int b) {"
Enter
Type "if (a > b) {"
Enter
Type "return a;"
Enter
Type "}"
Enter
Type "return b;"
Enter
Type "}"
Escape

# Wait for the live suggestion window via its static "dismiss" winbar label —
# deterministic chrome, not live AI text. (A Wait timeout aborts the whole
# recording, so we only ever Wait on guaranteed window chrome.)
# Generous @90s: the suggestion is a two-call cascade (evaluate -> teach), so the
# window can take a while on a slow provider. A Wait returns the instant the text
# matches, so a large timeout only costs time if the cascade genuinely stalls.
Wait+Screen@90s /dismiss/
# Pause on the suggestion so the explanation is readable on screen.
Sleep 5s

# Accept it: enter the learn-mode drill (suggestion.learn = Ctrl+L). The HUD's
# winbar carries the static "submit" label once the worked example renders.
Ctrl+L
Wait+Screen@90s /submit/
# Pause on the drill HUD so the worked example + instruction can be read.
Sleep 6s

# First (and only) attempt: write the idiomatic ternary straight away, so the
# drill is mastered on the first submit.
Type "i"
Sleep 200ms
Type "int larger(int a, int b) {"
Enter
Type "return a > b ? a : b;"
Enter
Type "}"
Escape
Sleep 500ms

# Submit (drilling.submit = Ctrl+S). Idiomatic -> the plugin notifies
# "you learned `...`" (deterministic mastery text) and keeps the clean code.
Ctrl+S
Wait+Screen@90s /you learned/
# Pause on the mastery notification + the clean, kept idiomatic code.
Sleep 4s

# Quit unsaved so demo.c stays pristine. Hide before quitting so the bare shell
# never shows at the end.
Hide
Type ":qa!"
Enter
Sleep 1s

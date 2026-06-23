Output demo.mp4

# Recorded to MP4 (a streaming H.264 encode — light on memory, never the 0-byte
# GIF you get when a long high-res recording overruns ffmpeg's palette pass).
# record.sh converts this MP4 to demo.gif for the README.

Require nvim

Set FontSize 18
Set Width 1280
Set Height 720
Set FontFamily "UbuntuMono Nerd Font"
Set Theme "nord"
Set Framerate 24
Set TypingSpeed 120ms
Set Padding 20
Set WindowBar "Colorful"
Set BorderRadius 12

# Open demo.c — it already contains one idiomatic function (sum)
Hide
Type "nvim -u init.lua demo.c"
Enter
Sleep 2s
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

# Wait for the live suggestion window. mercury is ~1-2s; the suggestion is a
# two-call cascade (evaluate -> teach), so give it a few seconds. (Fixed Sleep,
# not Wait: a Wait timeout aborts the whole recording, and a live AI is not
# guaranteed to print a given string — re-record if a take doesn't trigger.)
Sleep 6s

# Accept it: enter the learn-mode drill (suggestion.learn = Ctrl+L). Commenting
# the reference + the fresh line happen synchronously, so we can type right away;
# the worked-example HUD fills in a beat later.
Ctrl+L
Sleep 2s

# First attempt: fail on purpose by re-typing the same branchy version.
Type "i"
Sleep 200ms
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
Sleep 500ms

# Submit (drilling.submit = Ctrl+S). Still branchy -> the scaffold escalates to
# a closer, easier worked example.
Ctrl+S
Sleep 4s

# Collapse the four body lines into the idiomatic ternary and pass. From the
# closing brace: up to the `if`, delete the 4-line body, open a line above the
# brace, and write the ternary directly.
Type "4k"
Sleep 300ms
Type "4dd"
Sleep 300ms
Type "O"
Sleep 200ms
Type "return a > b ? a : b;"
Escape
Sleep 500ms
Ctrl+S
Sleep 4s

# Drill mastered: the comment reference is dropped, the idiomatic code kept.
# Move up to the original sum() and explain one of its lines.
Type "7G"
Sleep 500ms
Type "V"
Sleep 800ms

# Explain via the documented command. Pressing `:` from visual mode prefills the
# `'<,'>` range and, unlike the visual `<leader>` mapping, reliably sets the
# '< '> marks (the mapping's `visual_selection` bails on the session's *first*
# visual use, when `visualmode()` is still empty).
Type ":Learning explain"
Enter

# Show the explanation window (one ai.explain call).
Sleep 6s

# Dismiss the explanation (suggestion.dismiss = Escape) and quit unsaved so
# demo.c stays pristine for the next run.
Escape
Sleep 1s
Type ":qa!"
Enter
Sleep 1s

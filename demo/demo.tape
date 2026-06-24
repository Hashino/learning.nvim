Output demo.mp4

# Recorded to MP4 (a streaming H.264 encode — light on memory, never the 0-byte
# GIF you get when a long high-res recording overruns ffmpeg's palette pass).
# record.sh converts this MP4 to demo.gif for the README.

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

# Wait for the live suggestion window. The window's winbar carries the static
# "dismiss" action label — deterministic chrome, not live AI text — so we can
# anchor on it. (A Wait timeout aborts the whole recording, so we only ever Wait
# on guaranteed window chrome, never on the model's generated prose.)
Wait+Screen@30s /dismiss/

# Accept it: enter the learn-mode drill (suggestion.learn = Ctrl+L). The HUD's
# winbar carries the static "submit" label once the worked example renders.
Ctrl+L
Wait+Screen@30s /submit/

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

# Submit (drilling.submit = Ctrl+S). Still branchy -> the scaffold escalates: the
# plugin notifies it's "generating a more detailed explanation" (deterministic
# text), hides the HUD, then re-renders it (the "submit" label returns).
Ctrl+S
Wait+Screen@30s /generating a more detailed explanation/
Wait+Screen@30s /submit/

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

# Pass: the plugin notifies "you learned `...`" (deterministic mastery text).
Wait+Screen@30s /you learned/

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

# Wait for the explanation window (one ai.explain call) via its static "dismiss"
# winbar label, which can't appear before the window does.
Wait+Screen@30s /dismiss/
Sleep 2s

# Dismiss the explanation (suggestion.dismiss = Escape) and quit unsaved so
# demo.c stays pristine. Hide before quitting so the bare shell never shows.
Escape
Sleep 1s
Hide
Type ":qa!"
Enter
Sleep 1s

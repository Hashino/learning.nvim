Output explain-test.mp4

# A SHORT, cheap tape that exercises ONLY the explain feature — one ai.explain
# call, no drill cascade. Use it to eyeball the final GIF's quality (theme, font,
# dimensions, padding, window bar) before paying for the long, non-deterministic
# full demo.tape. Recorded to MP4; record.sh converts it to a GIF with the same
# ffmpeg pass the real demo uses:  TAPE=explain-test.tape ./demo/record.sh
#
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
# file's own text rather than a fixed Sleep, so we reveal a fully-loaded editor.
Hide
Type "nvim -u init.lua demo.c"
Enter
Wait+Screen@30s /sum of all elements/
Show
Sleep 1s

# Select the loop line inside sum() and explain it. `:` from visual mode prefills
# the `'<,'>` range and sets the '< '> marks reliably (the visual <leader>
# mapping bails on the session's first visual use — see demo.md).
Type "6G"
Sleep 500ms
Type "V"
Sleep 800ms
Type ":Learning explain"
Enter

# Wait for the explanation window instead of a fixed Sleep: this returns the
# instant it appears (no wasted seconds) and tolerates any provider latency.
# Anchor on "dismiss" — it's part of the window's static winbar ([learning.nvim] <Esc>
# dismiss), so it's guaranteed to appear, and it does NOT occur in the
# ":Learning explain" command line already on screen (which would match too
# early). The @30s timeout is generous; note a Wait TIMEOUT aborts the whole
# recording, so we only Wait on deterministic window chrome — never on the live
# AI's explanation text, which isn't guaranteed (that's why demo.tape's drill
# steps stay as fixed Sleeps).
Wait+Screen@30s /dismiss/
Sleep 2s

# Dismiss and quit unsaved so demo.c stays pristine. Hide before quitting so the
# bare shell never shows at the end.
Escape
Sleep 1s
Hide
Type ":qa!"
Enter
Sleep 1s

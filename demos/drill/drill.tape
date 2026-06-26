Output drill.mp4

# Records to MP4 (streaming H.264, never 0 bytes); record.sh converts it to
# drill.gif. A long live-AI recording can OOM VHS's direct GIF palette pass and
# silently yield a 0-byte file, so we go through MP4.

Require nvim

Set FontSize 18
Set Width 1280
Set Height 720
Set FontFamily "UbuntuMono Nerd Font"
Set Theme "nord"
Set Framerate 15
Set TypingSpeed 60ms
Set Padding 20
Set WindowBar "Colorful"
Set BorderRadius 12

# Open an empty drill.rs. Wait (hidden) for vim.pack to finish installing the
# colorscheme/showkeys plugins, then clear the install notice with a blank line.
Hide
Type "nvim drill.rs"
Enter
Sleep 25s
# blank line to clear vim.pack installation notice
Type ""
Enter
Show

# Type a non-idiomatic function: a for-loop that pushes into a fresh Vec, where
# an iterator chain (map + collect) is the idiomatic rewrite. Rust buffers get an
# indentexpr, so we type without leading spaces and let it indent.
Type "i"
Sleep 200ms
Type "fn doubled(xs: &[i32]) -> Vec<i32> {"
Enter
Type "let mut out = Vec::new();"
Enter
Type "for x in xs {"
Enter
Type "out.push(x * 2);"
Enter
Type "}"
Enter
Type "out"
Enter
Type "}"
Escape

# Wait for the live suggestion window's winbar ("dismiss" label).
# The notification "is going to teach you" appears in the cmdline and is
# unreliable in VHS's terminal; the winbar is rendered in the floating window.
Wait+Screen@300s /dismiss/
Sleep 5s

# Accept it: enter the learn-mode drill (suggestion.learn = Ctrl+L). The drill
# comments out the original below and opens a fresh line for the rewrite. The HUD
# opens immediately with the explanation (winbar carries the static "submit"
# label); the analogous example fills in as its prefetch lands.
Ctrl+L
Wait+Screen@180s /submit/
Sleep 6s

# The learner must fail TWICE on a rung before it escalates (drill_related_after
# = 2). So we make two wrong attempts: the second failure swaps the HUD to a
# closer, "different" example, and only then do we pass.

# Attempt 1 (wrong): a naive copy — returns the slice as a Vec without doubling
# and without the idiom. verify rejects it; the drill stays on the same rung and
# asks us to keep trying.
Type "i"
Sleep 200ms
Type "fn doubled(xs: &[i32]) -> Vec<i32> {"
Enter
Type "xs.to_vec()"
Enter
Type "}"
Escape
Sleep 2s
Ctrl+S
# the hardened verify returns a one-line hint: "[learning.nvim] incorrect answer: …"
Wait+Screen@90s /incorrect/
Sleep 5s

# Attempt 2 (wrong, but closer): a real middle ground — it DOES use an iterator
# (for_each), but still drives a mutable Vec, so it isn't the idiomatic
# map/collect. This is the SECOND failure: the drill escalates and the HUD swaps
# to a different, closer code snippet. ci{ replaces the function body in place;
# entering insert clears the previous notification so the next wait is real.
Type "ci{"
Sleep 300ms
Type "let mut out = Vec::new();"
Enter
Type "xs.iter().for_each(|x| out.push(x * 2));"
Enter
Type "out"
Escape
Sleep 2s
Ctrl+S
Wait+Screen@90s /incorrect/
# give the swapped-in "different" example time to render and be read.
Sleep 7s

# Pass: collapse the body into the iterator chain the drill teaches. Bind the
# closure arg by-value (|&x|) so it matches the canonical idiomatic form verify
# is anchored to — with |x| the items stay &i32 and mercury's verify rejects it
# as not the textbook rewrite.
Type "ci{"
Sleep 300ms
Type "xs.iter().map(|&x| x * 2).collect()"
Escape
Sleep 2s
Ctrl+S
# Pass: the plugin notifies "you learned `...`" (deterministic mastery text).
Wait+Screen@90s /you learned/
Sleep 10s

# Dismiss the suggestion and quit unsaved so drill.rs stays pristine.
Escape
Sleep 1s
Hide
Type ":qa!"
Enter
Sleep 1s

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
# comments out the original below and opens a fresh line for the rewrite; the
# HUD's winbar carries the static "submit" label once the example renders.
Ctrl+L
Wait+Screen@180s /submit/
Sleep 5s

# First attempt: a real middle ground — it DOES use an iterator (for_each), but
# still drives a mutable Vec, so it isn't the idiomatic map/collect the drill
# teaches. The drill rejects it and escalates to a closer example.
Type "i"
Sleep 200ms
Type "fn doubled(xs: &[i32]) -> Vec<i32> {"
Enter
Type "let mut out = Vec::new();"
Enter
Type "xs.iter().for_each(|x| out.push(x * 2));"
Enter
Type "out"
Enter
Type "}"
Escape
Sleep 500ms

# Submit (drilling.submit = Ctrl+S). Wait 3s before submitting to read the example.
Sleep 3s
Ctrl+S
Wait+Screen@60s /generating a more detailed explanation/
Wait+Screen@60s /submit/
Sleep 5s

# Pass: collapse the body into the iterator chain. ci{ changes inside the braces.
Type "ci{"
Sleep 300ms
Type "xs.iter().map(|x| x * 2).collect()"
Escape
Sleep 500ms

# Submit with 3s delay to read the example
Sleep 3s
Ctrl+S

# Pass: the plugin notifies "you learned `...`" (deterministic mastery text).
Wait+Screen@60s /you learned/
Sleep 10s

# Dismiss the suggestion and quit unsaved so drill.rs stays pristine.
Escape
Sleep 1s
Hide
Type ":qa!"
Enter
Sleep 1s

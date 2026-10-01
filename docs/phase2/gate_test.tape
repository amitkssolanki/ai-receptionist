# Shot 4 of the demo video (docs/phase2/DEMO_SCRIPT.md): the confirmation gate, sent Call #6's real recorded premature
# submit through the webhook, refuses it; the submit after the caller's "yes" is accepted.
# Render from the repository root (needs vhs, ttyd and ffmpeg):  vhs docs/phase2/gate_test.tape
# The video is written to tmp/demo/ (ignored by git).

Output tmp/demo/gate_test.mp4

Set Shell "bash"
Set FontSize 18
Set Width 1400
Set Height 520
Set Padding 24
Set TypingSpeed 40ms

# Load the project's Ruby (RVM gemset) off camera; -W0 hides interpreter warnings unrelated to the shot.
Hide
Type "source ~/.rvm/scripts/rvm && rvm use ruby-3.4.7@ai-receptionist >/dev/null 2>&1 && export RUBYOPT=-W0 && clear"
Enter
Sleep 2s
Show

Type "bin/rails test test/controllers/api/vapi/confirmation_gate_test.rb -n '/live_call_#6_end_to_end/' -v"
Sleep 600ms
Enter
Sleep 10s

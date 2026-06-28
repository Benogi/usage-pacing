#!/bin/bash
# test-resume.sh - Guided test of the visible scheduled resume (Variation A).
#
# Pass your session id (from the [usage-pacing] line injected at session start):
#   bash ~/.claude/usage-pacing/linux/test-resume.sh <session-id> [seconds]
#
# Schedules a resume to fire in a few seconds with a marker prompt, so you can watch
# the full Variation A pipeline quickly instead of waiting ~5h for a real reset.
# Confirms: does 'at' fire? does the terminal open? does the forked session auto-run?

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/claude-usage.py"
SESSION_ID="${1:-}"
IN_SECONDS="${2:-12}"

if [ -z "$SESSION_ID" ]; then
    echo "Need -SessionId <id>. Use the id from the [usage-pacing] line shown at session start."
    echo "Usage: $0 <session-id> [in-seconds]"
    exit 1
fi

MARKER="TEST-RESUME: reply with exactly the single line RESUME-AUTORUN-OK and then stop. Do not ask about pacing or do anything else."

echo "Scheduling a TEST resume to fire in ~${IN_SECONDS} seconds (forks this session; your current terminal is untouched)..."
python3 "$SCRIPT" --schedule-resume --session-id "$SESSION_ID" --work-dir "$(pwd)" --prompt "$MARKER" --in-seconds "$IN_SECONDS"

echo ""
echo "WATCH NOW (~${IN_SECONDS}s):"
echo "  1. A NEW terminal window opens."
echo "  2. It runs: claude --resume $SESSION_ID --fork-session ...  (a forked copy)."
echo "  3. RESULT:"
echo "       - new window prints 'RESUME-AUTORUN-OK' on its own  ->  auto-run WORKS. Done."
echo "       - new window sits at an empty prompt waiting          ->  auto-run does NOT work."
echo ""
echo "Cancel a pending test resume:"
echo "  python3 \"$SCRIPT\" --cancel-resume --session-id $SESSION_ID"

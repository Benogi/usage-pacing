#!/bin/bash
# activate.sh - (Re)install usage-pacing on Linux Mint
#
# * Adds SessionStart + UserPromptSubmit hook entries to ~/.claude/settings.json
#   (existing keys and unrelated hooks are preserved; our entries are de-duplicated)
# * Installs ~/.claude/CLAUDE.md from CLAUDE.global.md (the canonical copy here);
#   if a different CLAUDE.md already exists it is backed up to CLAUDE.md.prebak first
#
# settings.json is backed up to settings.json.bak before any change. Idempotent.
#
# Run:  bash ~/.claude/usage-pacing/linux/activate.sh

set -e

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
MD_BACKUP="$CLAUDE_DIR/CLAUDE.md.prebak"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/claude-usage.py"
CANON_MD="$SCRIPT_DIR/CLAUDE.global.md"
MARKER="claude-usage.py"
MD_MARKER="Usage self-pacing"

if [ ! -f "$SCRIPT" ]; then
    echo "Missing $SCRIPT - usage-pacing work not found. Aborting."
    exit 1
fi
if [ ! -f "$CANON_MD" ]; then
    echo "Missing $CANON_MD (canonical CLAUDE.md). Aborting."
    exit 1
fi

echo "Activating usage-pacing..."

SS_CMD="python3 \"$SCRIPT\" --session-start"
UP_CMD="python3 \"$SCRIPT\" --gate"

# ── Edit settings.json via Python (handles JSON correctly, no jq dependency) ──
export _UP_SETTINGS="$SETTINGS"
export _UP_MARKER="$MARKER"
export _UP_SS_CMD="$SS_CMD"
export _UP_UP_CMD="$UP_CMD"

python3 << 'PYEOF'
import json, os, shutil

settings_path = os.environ['_UP_SETTINGS']
marker        = os.environ['_UP_MARKER']
ss_cmd        = os.environ['_UP_SS_CMD']
up_cmd        = os.environ['_UP_UP_CMD']

if os.path.exists(settings_path):
    shutil.copy2(settings_path, settings_path + '.bak')
    with open(settings_path) as f:
        settings = json.load(f)
else:
    os.makedirs(os.path.dirname(settings_path), exist_ok=True)
    settings = {}

if not settings.get('hooks'):
    settings['hooks'] = {}

def set_our_hook(settings, event, command, marker):
    our_group = {"hooks": [{"type": "command", "command": command, "timeout": 15}]}
    existing  = settings['hooks'].get(event, [])
    foreign   = [g for g in existing
                 if not any(marker in h.get('command', '')
                            for h in (g.get('hooks') or []))]
    settings['hooks'][event] = foreign + [our_group]

set_our_hook(settings, 'SessionStart',     ss_cmd, marker)
set_our_hook(settings, 'UserPromptSubmit', up_cmd, marker)

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)
print("  settings.json: SessionStart + UserPromptSubmit hooks installed (backup: settings.json.bak)")
PYEOF

# ── Install CLAUDE.md ─────────────────────────────────────────────────────────
if [ -f "$CLAUDE_MD" ] && ! grep -q "$MD_MARKER" "$CLAUDE_MD" 2>/dev/null; then
    if [ ! -f "$MD_BACKUP" ]; then
        cp "$CLAUDE_MD" "$MD_BACKUP"
        echo "  CLAUDE.md: your existing file backed up to CLAUDE.md.prebak"
    fi
fi
cp "$CANON_MD" "$CLAUDE_MD"
echo "  CLAUDE.md: installed (opt-in prompt active for new sessions)"

echo "Done. New sessions will ask about pacing. (Current session unaffected - hooks load at start.)"

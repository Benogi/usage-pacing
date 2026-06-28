#!/bin/bash
# deactivate.sh - Revert Claude Code to stock state by removing ONLY usage-pacing modifications
#
# * Strips our hook entries from ~/.claude/settings.json (other keys & unrelated hooks kept)
# * Removes ~/.claude/CLAUDE.md if it's ours (restores pre-existing one if we had backed it up)
# * Does NOT delete anything in this folder — all our work stays put. Re-enable with activate.sh.
#
# settings.json is backed up to settings.json.bak before any change. Idempotent.
#
# Run:  bash ~/.claude/usage-pacing/linux/deactivate.sh

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
MD_BACKUP="$CLAUDE_DIR/CLAUDE.md.prebak"
MARKER="claude-usage.py"
MD_MARKER="Usage self-pacing"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Deactivating usage-pacing..."

# ── settings.json: remove our hooks only ─────────────────────────────────────
if [ -f "$SETTINGS" ]; then
    export _UP_SETTINGS="$SETTINGS"
    export _UP_MARKER="$MARKER"
    python3 << 'PYEOF'
import json, os, shutil

settings_path = os.environ['_UP_SETTINGS']
marker        = os.environ['_UP_MARKER']

shutil.copy2(settings_path, settings_path + '.bak')
with open(settings_path) as f:
    settings = json.load(f)

changed = False
hooks = settings.get('hooks') or {}
for event in list(hooks.keys()):
    original = hooks[event]
    kept = [g for g in original
            if not any(marker in h.get('command', '')
                       for h in (g.get('hooks') or []))]
    if len(kept) != len(original):
        changed = True
    if not kept:
        del hooks[event]
    else:
        hooks[event] = kept

if not hooks and 'hooks' in settings:
    del settings['hooks']

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)

if changed:
    print("  settings.json: removed our hooks (backup: settings.json.bak)")
else:
    print("  settings.json: no usage-pacing hooks present (nothing to remove)")
PYEOF
else
    echo "  settings.json: not found (nothing to do)"
fi

# ── CLAUDE.md: remove ours / restore pre-existing ────────────────────────────
if [ -f "$CLAUDE_MD" ] && grep -q "$MD_MARKER" "$CLAUDE_MD" 2>/dev/null; then
    rm "$CLAUDE_MD"
    if [ -f "$MD_BACKUP" ]; then
        mv "$MD_BACKUP" "$CLAUDE_MD"
        echo "  CLAUDE.md: removed ours, restored your previous CLAUDE.md"
    else
        echo "  CLAUDE.md: removed (stock state had none)"
    fi
else
    echo "  CLAUDE.md: not ours / absent (left untouched)"
fi

echo "Done. Stock Claude Code behavior restored. Your work in usage-pacing/linux/ is intact."
echo "Re-enable anytime: bash \"$SCRIPT_DIR/activate.sh\""

#!/bin/bash
# Install the Claude Code statusline from this repo.
# Symlinks the script into ~/.claude, so `git pull` here updates it in place.
set -e
repo_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p ~/.claude
ln -sf "$repo_dir/statusline-command.sh" ~/.claude/statusline-command.sh

# Merge the statusLine block into settings.json, keeping everything else
python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
d = {}
if os.path.exists(p):
    with open(p) as f:
        d = json.load(f)
d["statusLine"] = {"type": "command", "command": "bash ~/.claude/statusline-command.sh"}
with open(p, "w") as f:
    json.dump(d, f, indent=2)
PY

command -v jq >/dev/null || echo "WARNING: jq is not installed (apt install jq / brew install jq)"
echo "Statusline installed. Restart Claude Code."

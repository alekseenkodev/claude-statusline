# claude-statusline

Two-line status line for Claude Code: path, git branch with lines changed, model and effort,
context gradient bar, session cost, and 5h/7d rate limits with reset times.

## Install

```bash
git clone <repo-url> ~/claude-statusline
bash ~/claude-statusline/install.sh
```

Then restart Claude Code.

`install.sh` symlinks `statusline-command.sh` into `~/.claude/` and sets `statusLine` in
`~/.claude/settings.json` (other settings are kept). To update later: `git pull` in the repo.

Requires `jq`. Works on Linux and macOS.

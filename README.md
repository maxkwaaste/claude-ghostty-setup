# claude-ghostty-setup

My Claude Code setup for macOS and the [Ghostty](https://ghostty.org) terminal:

- **Status line** under the prompt showing model, context used (% and bar), context length, compactions, running subagents, and session/weekly usage. Built on [ccstatusline](https://github.com/sirmalloc/ccstatusline).
- **`cc`** starts Claude Code in *bypass all permissions* mode, so it works without approval prompts.
- **`/handoff`** hands a long session to a fresh one when the context fills up. It opens a new Claude in a split of the same Ghostty tab with a short summary prompt, has a headless Sonnet judge check that the new session understood, then closes the old split. Windows never move.
- Optional: my Ghostty config (Tokyo Night-ish colours, JetBrains Mono, `cmd-D` split right).

## Requirements

- macOS
- [Ghostty](https://ghostty.org) 1.3 or newer (needs the AppleScript `split` command; tested on 1.4.0)
- [Claude Code](https://docs.claude.com/en/docs/claude-code) (tested on 2.1.326), Node.js, Python 3, zsh
- `/handoff` asks macOS for permission the first time it controls Ghostty: allow it under System Settings > Privacy & Security > Automation.

## Install

```bash
git clone https://github.com/maxkwaaste/claude-ghostty-setup.git
cd claude-ghostty-setup
./install.sh            # add --ghostty to also install my Ghostty config
```

The installer backs up every file it overwrites (`*.bak-<timestamp>`). It:

| What | Where |
|------|-------|
| ccstatusline layout | `~/.config/ccstatusline/settings.json` |
| `statusLine` + `skipDangerousModePermissionPrompt` | merged into `~/.claude/settings.json` |
| `/handoff` command | `~/.claude/commands/handoff.md` |
| handoff helper | `~/.claude/helpers/handoff-tab.sh` |
| `cc` / `ca` aliases | `~/.config/claude-ghostty-setup/claude-aliases.zsh`, sourced from `~/.zshrc` |
| Ghostty config (with `--ghostty`) | `~/.config/ghostty/config` |

## Use

```bash
cc        # Claude Code, bypass all permissions
ca        # Claude Code, auto mode (the safer daily option)
```

In a long session type `/handoff`. Claude writes a short "Context from last session: ..." prompt, a new `cc` session starts in a split to the right, and once the judge confirms it picked up the right task the old split closes.

Settings:

| Env var | Default | Effect |
|---------|---------|--------|
| `HANDOFF_LAUNCH` | `cc` | command typed into the new split |
| `HANDOFF_TIMEOUT` | `600` | seconds to wait for the new session's first turn |
| `HANDOFF_RC` | auto | `1`/`0` forces Remote Control on/off for the new session |
| `HANDOFF_DRY_CLOSE` | unset | run everything but don't close the old split |
| `HANDOFF_PLACEMENT_TEST` | unset | only open and close a test split |
| `HANDOFF_FAKE_CLOSE_FAIL` | unset | skip the AppleScript close, to exercise the `/exit` fallback (combine with `HANDOFF_PLACEMENT_TEST`) |

Closing is verified. Ghostty's AppleScript `close` can report success without removing the split, so the watcher polls for up to 5 s until the terminal id is gone and retries once. If the split is still there, it types `/exit` into the old session and then `exit` into its shell, so the split closes because its process ended. The log only says `closed` after the id is confirmed gone; otherwise it says `NOT CLOSED` and you get a notification.

Log: `~/.claude/logs/handoff-tab.log`.

## A warning about bypass mode

`cc` lets Claude edit files and run any shell command without asking. That is fast, and it also means a bad instruction (from you, or hidden in a web page or repo Claude reads) runs unchecked. Use it in projects you trust, keep backups or git, and prefer `ca` when you're unsure. `skipDangerousModePermissionPrompt` only hides the start-up warning; remove it from `~/.claude/settings.json` if you want the warning back.

## License

MIT

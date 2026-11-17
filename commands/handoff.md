---
name: handoff
description: "Hand the session to a fresh Claude in a split of this Ghostty tab, check that it understood, then close this split. No window ever moves."
---

# /handoff: new split, verified pickup, this split closes

Write the prompt that lets a fresh Claude session pick up exactly where this one
stops, start that session in a split of this same Ghostty tab, and let a
watcher close this split once the new session has answered.

## Do this

1. Compose the prompt from what is already in this conversation. Do not go
   reading files, running git, or searching to pad it out. If you do not know
   something, leave it out.

   Shape, under 150 words, compact prose, no headings, no bullets:

   > Context from last session: <what was done>. <where it lives, absolute
   > paths>. <what is next>. <gotchas worth knowing>.

2. If you have a memory tool (an MCP memory server, a notes file), save the same
   context there now. This split closes shortly after step 3.

3. Write two files to a temp or scratchpad directory with the Write tool:
   - the prompt (plain text, no launcher wrapper, no quoting);
   - the expectation: 1 to 3 plain sentences, from you as the writer, saying
     what the new session must understand and do FIRST (task, next step, key
     files, any "do not"). This is what the judge grades against, so be concrete.

   Then run:

   ```bash
   ~/.claude/helpers/handoff-tab.sh <prompt-file> <expect-file>
   ```

   The helper finds this session's Ghostty terminal by tty, splits it to the
   right and starts `cc "<prompt>"` in the new pane (override the launcher with
   `HANDOFF_LAUNCH`). Then it starts a detached watcher. A split is used instead
   of a tab because a new macOS tab is a new window, and with macOS window
   tiling that makes Ghostty windows jump (ghostty-org/ghostty#2565). A split
   only changes the tab's own surface tree, so no window moves.

   If this session has Remote Control on, the new session gets
   `--remote-control "Handoff <date time>"` too. `HANDOFF_RC=1` or `0` forces it.

   The watcher finds the new session's transcript (by a `(handoff-<id>)` marker
   appended to the prompt) and waits for its first finished turn, or 8 tool
   calls. A headless Sonnet judge (`claude -p`, no tools, no MCP) then compares
   the prompt, your expectation, and what the new session said and did. On "ok"
   the old split closes and the new session fills the tab. On "mismatch" the
   judge's correction is typed into the new session once and judged again. A
   second mismatch, an API error or the timeout (600s, `HANDOFF_TIMEOUT`) keeps
   this split open, copies the launch command to the clipboard and shows a
   notification. Log: `~/.claude/logs/handoff-tab.log`.

4. Reply with one line: `Handoff started, this split closes once the new session has shown it understood.`
   Nothing else.

If the helper exits non-zero (not running in Ghostty, AppleScript failure), fall
back to copying the command: `printf '%s' 'cc "<prompt>"' | pbcopy` (single-quote
the outer string, escape `'` as `'\''` and `"` as `\"`) and reply `Handoff copied.`

## When not to run it

Nothing to resume means no handoff. A question answered, a one-off script, a
quick fix: say so in one line and stop.

## Testing

`HANDOFF_DRY_CLOSE=1 ~/.claude/helpers/handoff-tab.sh <file>` runs the whole flow
including the judge, but only logs `DRY: would close <terminal>`. Close the test
split by hand.

`HANDOFF_PLACEMENT_TEST=1 ~/.claude/helpers/handoff-tab.sh <file>` only checks
placement: it opens a split running `echo`, prints the tab's terminals and
closes that split again. No Claude session gets started.

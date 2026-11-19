#!/bin/bash
# handoff-tab.sh — hand this Claude session to a fresh one in a Ghostty split
# of this same tab, without moving any window, and only let go once the new
# session has shown it understood the handoff.
#
# Usage: handoff-tab.sh <prompt-file> [<expect-file>]
#          prompt-file: the handoff prompt (plain text, no launcher wrapper)
#          expect-file: the writer's own statement of what the new session should
#                       understand and do first (1-3 sentences). Optional but
#                       strongly recommended: the judge grades against it.
#        handoff-tab.sh --watch <args...>   (internal: the detached watcher)
#
# Layout rule: no Ghostty window may move, ever. A native macOS tab is a new
# NSWindow that AppKit merges into the tab group (Ghostty TerminalController
# newTab -> addTabbedWindow), and with macOS window tiling that visibly jumps
# windows (ghostty-org/ghostty#2565); restoring frames afterwards only shortens
# the jump. A split is a change to the tab's own surface tree
# (BaseTerminalController.newSplit -> replaceSurfaceTree) with no window or
# frame call, so the new session starts as a split to the right of this one in
# the same tab. When the handoff is confirmed the old split is closed (AppleScript
# "close" = closeSurface withConfirmation:false) and the new one fills the tab.
# Everything is looked up by terminal id, never by index.
#
# Confirmation = the new session finished its first turn (or made 8 tool calls)
# AND a headless Sonnet judge, given prompt + expectation + what the session
# said and did, rules "ok". On "mismatch" the judge's correction is typed into
# the new session once and the judge runs again. Second mismatch, error or
# timeout: the old tab stays open, the launch command goes on the clipboard, and a
# notification says why.
set -u
# Command typed into the new split. Default is the `cc` alias from shell/claude-aliases.zsh.
LAUNCH="${HANDOFF_LAUNCH:-cc}"
LOG="$HOME/.claude/logs/handoff-tab.log"
mkdir -p "$(dirname "$LOG")"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }
notify() { osascript - "$1" >/dev/null 2>&1 <<'EOF'
on run argv
  display notification (item 1 of argv) with title "Handoff"
end run
EOF
}

find_claude_tty() {
  local p=$$ comm tty
  while [ "${p:-1}" -gt 1 ]; do
    comm=$(ps -o comm= -p "$p" 2>/dev/null)
    tty=$(ps -o tty= -p "$p" 2>/dev/null | tr -d ' ')
    if [[ "$comm" == *claude* && "$tty" == ttys* ]]; then echo "/dev/$tty $p"; return 0; fi
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
  return 1
}

# Type a line into the new session's terminal and press enter.
type_into_term() { # <terminal-id> <text>
  osascript - "$1" "$2" >>"$LOG" 2>&1 <<'EOF'
on run argv
  tell application "Ghostty"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with term in terminals of t
          if (id of term) is (item 1 of argv) then
            input text (item 2 of argv) to term
            delay 0.3
            send key "enter" to term
            return "typed"
          end if
        end repeat
      end repeat
    end repeat
  end tell
  error "terminal not found"
end run
EOF
}

# Is a terminal with this id still in Ghostty? Exit 0 = yes, 1 = gone, 2 = could
# not ask (Ghostty did not answer; treated as "still there" by callers).
term_exists() { # <terminal-id>
  local ids
  ids=$(osascript -e 'tell application "Ghostty" to get id of every terminal' 2>/dev/null) || return 2
  [[ ", $ids, " == *", $1, "* ]]
}

# Poll up to <secs> for the terminal to disappear. Exit 0 = gone.
wait_term_gone() { # <terminal-id> <secs>
  local end=$(( $(date +%s) + $2 ))
  while :; do
    term_exists "$1"; [ $? = 1 ] && return 0
    [ "$(date +%s)" -ge "$end" ] && return 1
    sleep 0.5
  done
}

# Ask Ghostty to close one terminal, addressed by its unique id (not by window or
# tab index, which can shift while you move focus). Prints Ghostty's answer.
send_close() { # <terminal-id>
  [ -n "${HANDOFF_FAKE_CLOSE_FAIL:-}" ] && { echo "skipped (HANDOFF_FAKE_CLOSE_FAIL)"; return 0; }
  osascript - "$1" 2>&1 <<'EOF'
on run argv
  tell application "Ghostty"
    close terminal id (item 1 of argv)
  end tell
  return "close sent"
end run
EOF
}

has_claude_on() { # <tty path> -> exit 0 if a claude process still runs there
  ps -t "${1#/dev/}" -o comm= 2>/dev/null | grep -q claude
}

# Close a terminal and prove it is gone. Ghostty's AppleScript "close" calls
# closeSurface(withConfirmation: false), so confirm-close-surface never shows a
# sheet, but the handler returns success even when the surface is not removed
# (observed with Ghostty 1.4.0: close event received, no sheet, no error, yet
# the split stayed open until closed by hand). So: close, poll, and if the
# terminal is still there, retry once, then end Claude with /exit and the shell
# with exit, so the surface closes because its process ended.
# Logs every step; logs "closed" only after the id is verified gone.
# Exit 0 = verified gone, 1 = still open.
close_term_verified() { # <terminal-id> <label>
  local id="$1" what="$2" out tty
  term_exists "$id"
  if [ $? = 1 ]; then log "close $what $id: already gone"; return 0; fi
  for attempt in 1 2; do
    out=$(send_close "$id"); log "close $what $id: attempt $attempt: ghostty said: ${out:-<nothing>}"
    if wait_term_gone "$id" 5; then log "closed $what $id (verified gone after close attempt $attempt)"; return 0; fi
    log "close $what $id: still present 5s after close attempt $attempt"
  done
  tty=$(osascript - "$id" 2>/dev/null <<'EOF'
on run argv
  tell application "Ghostty" to return tty of terminal id (item 1 of argv)
end run
EOF
)
  if [ "${HANDOFF_FAKE_CLOSE_FAIL:-}" = all ]; then
    log "close $what $id: fallback skipped (HANDOFF_FAKE_CLOSE_FAIL=all)"; tty=""
  else
    log "close $what $id: fallback, typing /exit into it (tty ${tty:-unknown})"
    type_into_term "$id" "/exit" || log "close $what $id: typing /exit failed"
  fi
  if [ -n "$tty" ]; then
    local end=$(( $(date +%s) + 15 ))
    while has_claude_on "$tty" && [ "$(date +%s)" -lt "$end" ]; do sleep 0.5; done
    if has_claude_on "$tty"; then
      log "close $what $id: claude still running on $tty 15s after /exit, not typing exit into it"
    else
      log "close $what $id: no claude on $tty, typing exit into the shell"
      wait_term_gone "$id" 2 || type_into_term "$id" "exit" || log "close $what $id: typing exit failed"
    fi
  fi
  if wait_term_gone "$id" 5; then log "closed $what $id (verified gone after /exit fallback)"; return 0; fi
  out=$(send_close "$id"); log "close $what $id: final close attempt: ghostty said: ${out:-<nothing>}"
  if wait_term_gone "$id" 5; then log "closed $what $id (verified gone after final close)"; return 0; fi
  log "NOT CLOSED: $what $id is still open after close x3 and /exit fallback"
  return 1
}

if [ "${1:-}" = "--watch" ]; then
  # ---------------- detached watcher ----------------
  OLD_TAB="$2"; NEW_TAB="$3"; OLD_INDEX="$4"; MARKER="$5"; PROJ_DIR="$6"
  REF="$7"; CMD_FILE="$8"; PROMPT_FILE="$9"; EXPECT_FILE="${10}"
  TIMEOUT="${HANDOFF_TIMEOUT:-600}"
  FIXTAG="handoff-fix-${MARKER#handoff-}"
  log "watch: marker=$MARKER old_tab=$OLD_TAB new_tab=$NEW_TAB old_index=$OLD_INDEX"
  cleanup() { rm -f "$REF" "$PROMPT_FILE" "$EXPECT_FILE" "$STATE_DIR"/"$MARKER".snap; }
  STATE_DIR=$(dirname "$REF")
  fail() {
    log "FAIL: $1"
    if [ -n "${HANDOFF_NO_CLIPBOARD:-}" ]; then
      log "test: clipboard and notification skipped (HANDOFF_NO_CLIPBOARD)"
    else
      pbcopy <"$CMD_FILE"
      notify "Handoff not confirmed: $1. Old tab kept, launch command copied."
    fi
    exit 1
  }

  # Wait for the transcript, then for a turn to judge. $1 = anchor string.
  wait_for_turn() {
    local anchor="$1" out
    while [ "$(date +%s)" -lt "$deadline" ]; do
      if [ -z "$transcript" ]; then
        # The marker must sit in a real user prompt. Any other session that merely
        # printed this log (a tool_result quoting the marker) would otherwise be
        # picked, and the judge would wait on the wrong session until timeout.
        transcript=$(find "$PROJ_DIR" -maxdepth 1 -name '*.jsonl' -newer "$REF" -print0 2>/dev/null \
          | xargs -0 grep -l -F "$MARKER" 2>/dev/null \
          | python3 -I -c '
import json, sys
marker = sys.argv[1]
for path in sys.stdin.read().splitlines():
    for line in open(path, encoding="utf-8", errors="replace"):
        if marker not in line: continue
        try: d = json.loads(line)
        except Exception: continue
        m = d.get("message") if isinstance(d.get("message"), dict) else {}
        c = m.get("content", "")
        if isinstance(c, list) and any(isinstance(x, dict) and x.get("type") == "tool_result" for x in c): continue
        if d.get("type") == "user" and marker in json.dumps(c): print(path); sys.exit()
' "$MARKER")
        [ -n "$transcript" ] && log "transcript: $transcript"
      fi
      if [ -n "$transcript" ]; then
        out=$(python3 -I - "$transcript" "$anchor" "$STATE_DIR/$MARKER.snap" <<'PY'
import json, sys
path, anchor, snap = sys.argv[1:4]
started = False; state = "wait"; parts = []; tools = 0
for line in open(path, encoding="utf-8", errors="replace"):
    try: d = json.loads(line)
    except Exception: continue
    m = d.get("message") if isinstance(d.get("message"), dict) else {}
    content = m.get("content", "")
    # A tool_result can quote the anchor (e.g. tailing the log); only a real
    # prompt starts a turn.
    is_result = isinstance(content, list) and any(
        isinstance(c, dict) and c.get("type") == "tool_result" for c in content)
    if d.get("type") == "user" and not is_result and anchor in json.dumps(content):
        started = True; parts = []; tools = 0; state = "wait"; continue
    if not started or d.get("type") != "assistant": continue
    if d.get("isApiErrorMessage") or d.get("error"):
        state = "error:" + str(d.get("error") or "api error")[:80]; break
    visible = False
    for c in m.get("content", []) or []:
        if not isinstance(c, dict): continue
        if c.get("type") == "text" and c.get("text", "").strip():
            parts.append("SAID: " + c["text"].strip()); visible = True
        elif c.get("type") == "tool_use":
            tools += 1; visible = True
            parts.append("TOOL %s: %s" % (c.get("name"), json.dumps(c.get("input", {}))[:300]))
    # The thinking block lands as its own line already stamped end_turn, a few
    # ms before the reply text. Only an end_turn line with visible content
    # closes the turn; otherwise keep polling until the text is flushed.
    if (m.get("stop_reason") == "end_turn" and visible) or tools >= 8:
        state = "ready"; break
if state == "ready":
    text = "\n".join(parts)
    if len(text) > 12000: text = text[:6000] + "\n[...]\n" + text[-6000:]
    open(snap, "w").write(text)
print(state)
PY
)
        case "$out" in
          ready) return 0 ;;
          error:*) fail "${out#error:}" ;;
        esac
      fi
      sleep 3
    done
    fail "no finished turn from the new session within ${TIMEOUT}s"
  }

  # Ask a headless judge whether the new session understood. Prints "ok" or
  # "mismatch<TAB>correction".
  judge() {
    python3 -I - "$PROMPT_FILE" "$EXPECT_FILE" "$STATE_DIR/$MARKER.snap" "$MARKER" <<'PY'
import json, re, subprocess, sys
pf, ef, sf, marker = sys.argv[1:5]
prompt = open(pf).read().replace("(%s)" % marker, "").strip()
try: expect = open(ef).read().strip()
except Exception: expect = ""
seen = open(sf).read()
q = f"""You are checking a session handoff between two Claude Code sessions.
The previous session (the writer) handed off with this prompt:
<handoff_prompt>
{prompt}
</handoff_prompt>
The writer's own statement of what the new session should understand and do first:
<writer_expectation>
{expect or "(none given; infer it from the prompt)"}
</writer_expectation>
This is what the new session said and did in its first turn:
<new_session>
{seen}
</new_session>
Decide whether the new session understood the handoff: is it working on the right
task, at the right next step, with the right files and constraints, and not doing
something the writer did not ask for? Small differences in approach are fine.
Answer with only a JSON object: {{"verdict": "ok" or "mismatch", "reason": "<one sentence>",
"correction": "<if mismatch: one or two plain sentences addressed to the new session that set it straight; else empty>"}}"""
try:
    r = subprocess.run(["claude", "-p", "--model", "sonnet", "--no-session-persistence",
        "--setting-sources", "project", "--strict-mcp-config", "--tools", "",
        "--disable-slash-commands", "--output-format", "json"],
        input=q, capture_output=True, text=True, timeout=120, cwd="/tmp")
    res = json.loads(r.stdout).get("result", "")
    v = json.loads(re.search(r"\{.*\}", res, re.S).group(0))
except Exception as e:
    print("error\tjudge failed: %s" % str(e)[:100]); sys.exit()
reason = v.get("reason", "").replace("\t", " ").replace("\n", " ")
if v.get("verdict") == "ok":
    print("ok\t" + reason)
else:
    print("mismatch\t" + reason + "\t" + v.get("correction", "").replace("\t", " ").replace("\n", " "))
PY
  }

  deadline=$(( $(date +%s) + TIMEOUT )); transcript=""
  anchor="$MARKER"
  for round in 1 2; do
    wait_for_turn "$anchor"
    IFS=$'\t' read -r verdict reason correction <<<"$(judge)"
    log "judge round $round: $verdict: $reason"
    case "$verdict" in
      ok) break ;;
      mismatch)
        if [ "$round" = 2 ]; then fail "still off track after a correction ($reason)"; fi
        log "correcting: $correction"
        anchor="$FIXTAG"
        type_into_term "$NEW_TAB" "Note from the handoff check: $correction ($FIXTAG)" \
          || fail "could not type the correction into the new session"
        ;;
      *) fail "${reason:-judge gave no verdict}" ;;
    esac
  done

  log "OK: new session understood the handoff, closing $OLD_TAB"
  if [ -n "${HANDOFF_DRY_CLOSE:-}" ]; then
    log "DRY: would close $OLD_TAB"; notify "Dry run OK, would close the old tab."
    rm -f "$CMD_FILE"; cleanup; exit 0
  fi
  if ! close_term_verified "$OLD_TAB" "old split"; then
    [ -n "${HANDOFF_NO_CLIPBOARD:-}" ] || notify "New session is running, but the old split would not close. Close it by hand."
    rm -f "$CMD_FILE"; cleanup; exit 1
  fi
  rm -f "$CMD_FILE"; cleanup
  exit 0
fi

# ---------------- launcher ----------------
PROMPT_IN="${1:?usage: handoff-tab.sh <prompt-file> [<expect-file>]}"
EXPECT_IN="${2:-}"
[ -s "$PROMPT_IN" ] || { echo "prompt file empty: $PROMPT_IN" >&2; exit 2; }
read -r MY_TTY CLAUDE_PID < <(find_claude_tty) || true
[ -n "${MY_TTY:-}" ] || { echo "could not find this session's tty (not in Ghostty?)" >&2; exit 3; }
CWD=$(lsof -a -p "$CLAUDE_PID" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
[ -d "${CWD:-}" ] || CWD="$PWD"
PROJ_DIR="$HOME/.claude/projects/$(printf '%s' "$CWD" | sed 's#[^A-Za-z0-9]#-#g')"
MARKER="handoff-$(date +%s)-$RANDOM"
STATE="$HOME/.claude/handoff"; mkdir -p "$STATE"
PFILE="$STATE/$MARKER.txt"; CMD_FILE="$STATE/$MARKER.cmd"; EFILE="$STATE/$MARKER.expect"
{ cat "$PROMPT_IN"; printf ' (%s)' "$MARKER"; } >"$PFILE"
if [ -n "$EXPECT_IN" ] && [ -s "$EXPECT_IN" ]; then cp "$EXPECT_IN" "$EFILE"; else : >"$EFILE"; fi
# Remote Control: if this session has RC on (started with --remote-control/--rc,
# or /remote-control turned on mid-session, which writes a bridge_status
# "is active" or bridge-session line to the transcript), start the new one with
# RC too, so you can keep driving it from your phone. The name is given
# explicitly because --remote-control takes an optional value and would
# otherwise swallow the prompt. HANDOFF_RC=1/0 forces it on/off.
rc_active() {
  [ -n "${HANDOFF_RC:-}" ] && { [ "$HANDOFF_RC" = 1 ]; return; }
  ps -o args= -p "$CLAUDE_PID" 2>/dev/null | grep -qE -- '--(remote-control|rc)( |=|$)' && return 0
  local sid tr
  sid=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sessionId",""))' \
        "$HOME/.claude/sessions/$CLAUDE_PID.json" 2>/dev/null)
  tr="$PROJ_DIR/$sid.jsonl"
  [ -n "$sid" ] && [ -f "$tr" ] && grep -qE '"subtype":"bridge_status","content":"/remote-control is active|"type":"bridge-session"' "$tr"
}
RC_FLAG=""; RC_NAME=""
if rc_active; then RC_NAME="Handoff $(date '+%d %b %H:%M')"; RC_FLAG="--remote-control '$RC_NAME' "; fi
python3 -I -c 'import sys,shlex; n=sys.argv[2]; launch=sys.argv[3]; print(launch + " " + ("--remote-control " + shlex.quote(n) + " " if n else "") + shlex.quote(open(sys.argv[1]).read()), end="")' "$PFILE" "$RC_NAME" "$LAUNCH" >"$CMD_FILE"
REF="$STATE/$MARKER.ref"; touch "$REF"

CMD="${LAUNCH} ${RC_FLAG}\"\$(cat '$PFILE')\""
[ -n "${HANDOFF_PLACEMENT_TEST:-}" ] && CMD="echo handoff placement test"

# Start the new session as a split to the right of this one, in this same tab.
# No window or tab is created, so no window frame can change.
PLACED=$(osascript - "$MY_TTY" "$CWD" "$CMD" <<'EOF'
on run argv
  set myTty to item 1 of argv
  set theDir to item 2 of argv
  set theCmd to item 3 of argv
  tell application "Ghostty"
    set oldTerm to missing value
    repeat with w in windows
      repeat with t in tabs of w
        repeat with term in terminals of t
          if (tty of term) is myTty then
            set oldTerm to contents of term
            set winId to id of w
            set tabId to id of t
          end if
        end repeat
      end repeat
    end repeat
    if oldTerm is missing value then error "no Ghostty terminal with tty " & myTty
    set cfg to new surface configuration
    set initial working directory of cfg to theDir
    set initial input of cfg to theCmd & return
    set newTerm to split oldTerm direction right with configuration cfg
    return (id of oldTerm) & " " & (id of newTerm) & " " & tabId & " " & winId
  end tell
end run
EOF
) || { echo "could not open a Ghostty split" >&2; pbcopy <"$CMD_FILE"; exit 4; }
read -r OLD_TAB NEW_TAB TAB_ID WIN_ID <<<"$PLACED"
OLD_INDEX="-"
log "launch: tty=$MY_TTY win=$WIN_ID tab=$TAB_ID old_term=$OLD_TAB new_term=$NEW_TAB (split) cwd=$CWD marker=$MARKER rc=${RC_NAME:-off}"

if [ -n "${HANDOFF_PLACEMENT_TEST:-}" ]; then
  # Report the tab's terminals, then close the test split again (verified).
  sleep 1
  osascript - "$TAB_ID" <<'EOF'
on run argv
  tell application "Ghostty"
    set out to ""
    repeat with w in windows
      repeat with t in tabs of w
        if (id of t) is (item 1 of argv) then
          repeat with term in terminals of t
            set out to out & (id of term) & " tty=" & (tty of term) & linefeed
          end repeat
        end if
      end repeat
    end repeat
    return out
  end tell
end run
EOF
  rm -f "$PFILE" "$CMD_FILE" "$EFILE" "$REF"
  if close_term_verified "$NEW_TAB" "test split"; then echo "test split closed (verified)"; exit 0; fi
  echo "test split NOT closed, see $LOG" >&2
  if [ -n "${HANDOFF_FAKE_CLOSE_FAIL:-}" ]; then
    # Forced failure: clean the split up for real so the test leaves nothing behind.
    HANDOFF_FAKE_CLOSE_FAIL="" close_term_verified "$NEW_TAB" "test split cleanup" \
      && echo "test split cleaned up (verified)" >&2
  fi
  exit 5
fi

HANDOFF_DRY_CLOSE="${HANDOFF_DRY_CLOSE:-}" nohup "$0" --watch "$OLD_TAB" "$NEW_TAB" "$OLD_INDEX" \
  "$MARKER" "$PROJ_DIR" "$REF" "$CMD_FILE" "$PFILE" "$EFILE" </dev/null >>"$LOG" 2>&1 &
disown
echo "new session started in a split of this tab${RC_NAME:+ with Remote Control on ($RC_NAME)}, watcher pid $! (log: $LOG)"

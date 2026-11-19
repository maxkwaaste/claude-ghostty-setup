#!/bin/bash
# tests/handoff-paths.sh: drive handoff-tab.sh through every path the live
# handoffs rarely hit, against real Ghostty splits and the real judge.
#
#   P1 placement, normal close        P5 judge mismatch, then ok after correction
#   P2 retry + /exit fallback         P6 judge mismatch twice -> FAIL, old split kept
#   P3 every close fails -> NOT CLOSED P7 no finished turn -> timeout FAIL
#   P4 judge ok, decoy transcript     P8 API error in the new session -> FAIL
#
# Run it from inside a Ghostty terminal (it splits that terminal), from a plain
# shell or from Claude. It opens and
# closes its own splits, never touches the clipboard (HANDOFF_NO_CLIPBOARD) and
# costs four or five short Sonnet judge calls. Exit 0 = all green.
set -u
H="${HANDOFF_SCRIPT:-$(cd "$(dirname "$0")/.." && pwd)/helpers/handoff-tab.sh}"
LOG="$HOME/.claude/logs/handoff-tab.log"
W=$(mktemp -d "${TMPDIR:-/tmp}/handoff-paths.XXXXXX")
PASS=0; FAILS=()
export HANDOFF_NO_CLIPBOARD=1
mkdir -p "$(dirname "$LOG")"; touch "$LOG"   # a machine that never handed off has no log yet
# The launcher finds its own split by walking up to a process whose name holds
# "claude" (normally the Claude session that ran /handoff). Run the placement
# tests through a symlink to bash with such a name, so the suite also works from
# a plain shell. (A copy of /bin/bash is killed by code signing; a symlink is not,
# and ps reports the link's path.)
SHIM="$W/claude-test-shell"; ln -s /bin/bash "$SHIM"
place() { "$SHIM" "$H" "$W/p.txt" >/dev/null 2>&1; }

my_tty() { local p=$$ t
  while [ "${p:-1}" -gt 1 ]; do
    t=$(ps -o tty= -p "$p" 2>/dev/null | tr -d ' ')
    [[ "$t" == ttys* ]] && { echo "/dev/$t"; return 0; }
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done; return 1; }
TTY=$(my_tty) || { echo "not inside a terminal" >&2; exit 2; }

# A split next to ours running cat, so typed text lands somewhere harmless.
mk_split() { osascript - "$TTY" <<'EOF'
on run argv
  tell application "Ghostty"
    repeat with term in terminals
      if (tty of term) is (item 1 of argv) then
        set cfg to new surface configuration
        set initial input of cfg to "exec cat >/dev/null" & return
        set n to split (contents of term) direction down with configuration cfg
        return id of n
      end if
    end repeat
  end tell
  error "no terminal on " & (item 1 of argv)
end run
EOF
}
exists() { [[ ", $(osascript -e 'tell application "Ghostty" to get id of every terminal'), " == *", $1, "* ]]; }
kill_split() { exists "$1" && osascript -e "tell application \"Ghostty\" to close terminal id \"$1\"" >/dev/null 2>&1; true; }

ok()  { PASS=$((PASS+1)); echo "  PASS $1"; }
bad() { FAILS+=("$1"); echo "  FAIL $1"; }
since() { tail -n +"$(( $1 + 1 ))" "$LOG"; }
has() { since "$1" | grep -qF -- "$2"; }

# jsonl writer: user prompt / assistant reply / tool_result / api error
jl() { python3 -I - "$@" <<'PY'
import json, sys
f, kind, text = sys.argv[1:4]
if kind == "user": d = {"type": "user", "message": {"role": "user", "content": text}}
elif kind == "said": d = {"type": "assistant", "message": {"role": "assistant", "stop_reason": "end_turn", "content": [{"type": "text", "text": text}]}}
elif kind == "result": d = {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "x", "content": text}]}}
elif kind == "apierr": d = {"type": "assistant", "isApiErrorMessage": True, "error": text, "message": {"role": "assistant", "content": [{"type": "text", "text": "API Error"}]}}
open(f, "a").write(json.dumps(d) + "\n")
PY
}

PROMPT='Context from last session: the nightly backup script ~/bin/backup.sh was fixed to skip the Photos library. Next: run `~/bin/backup.sh --dry-run` once and report in two lines whether Photos is skipped. Do not change any file.'
GOOD='I will run ~/bin/backup.sh --dry-run once, read whether the Photos library is listed as skipped, and report that in two lines without editing anything.'
BAD='I rewrote ~/bin/backup.sh from scratch to use rsync, deleted the old log files and pushed the change to main.'

# Set up a watcher scenario: prints "<marker> <projdir> <ref> <cmd> <prompt> <expect>"
scenario() { local m="handoff-test$(date +%s)$RANDOM" d="$W/$1"
  mkdir -p "$d/proj"; printf '%s (%s)' "$PROMPT" "$m" >"$d/prompt"
  echo "Run the dry run once and report whether Photos is skipped; change nothing." >"$d/expect"
  echo "cc test" >"$d/cmd"; touch "$d/ref"; sleep 1.1
  echo "$m $d/proj $d/ref $d/cmd $d/prompt $d/expect"; }
watch() { "$H" --watch "$1" "$2" - "${@:3}" >/dev/null 2>&1; }

echo "== placement + close paths"
printf 'test\n' >"$W/p.txt"
N=$(wc -l <"$LOG"); HANDOFF_PLACEMENT_TEST=1 place
has "$N" "(verified gone after close attempt 1)" && ok "P1 normal close" || bad "P1 normal close"
N=$(wc -l <"$LOG"); HANDOFF_PLACEMENT_TEST=1 HANDOFF_FAKE_CLOSE_FAIL=1 place
has "$N" "(verified gone after /exit fallback)" && ok "P2 retry + /exit fallback" || bad "P2 retry + /exit fallback"
N=$(wc -l <"$LOG"); HANDOFF_PLACEMENT_TEST=1 HANDOFF_FAKE_CLOSE_FAIL=all place; rc=$?
if [ $rc = 5 ] && has "$N" "NOT CLOSED: test split" && has "$N" "closed test split cleanup"; then ok "P3 NOT CLOSED (exit 5, cleaned up)"; else bad "P3 NOT CLOSED (rc=$rc)"; fi

echo "== judge paths (real Sonnet judge)"
# P4: ok on round 1; a decoy transcript quotes the marker in a tool_result and must be ignored.
read -r M P R C PF EF <<<"$(scenario p4)"
jl "$P/decoy.jsonl" user "tail the log"; jl "$P/decoy.jsonl" result "watch: marker=$M"
jl "$P/real.jsonl" user "$PROMPT ($M)"; jl "$P/real.jsonl" said "$GOOD"
OLD=$(mk_split); NEW=$(mk_split); N=$(wc -l <"$LOG")
watch "$OLD" "$NEW" "$M" "$P" "$R" "$C" "$PF" "$EF"
if has "$N" "transcript: $P/real.jsonl" && has "$N" "judge round 1: ok" && has "$N" "closed old split $OLD (verified gone" && ! exists "$OLD"; then
  ok "P4 judge ok, right transcript, old split closed"; else bad "P4 judge ok"; fi
kill_split "$OLD"; kill_split "$NEW"

# P5: mismatch, correction typed into the new split, then ok.
read -r M P R C PF EF <<<"$(scenario p5)"
jl "$P/real.jsonl" user "$PROMPT ($M)"; jl "$P/real.jsonl" said "$BAD"
OLD=$(mk_split); NEW=$(mk_split); N=$(wc -l <"$LOG")
( end=$(( $(date +%s) + 200 ))
  until has "$N" "correcting:" || [ "$(date +%s)" -ge "$end" ]; do sleep 1; done
  jl "$P/real.jsonl" user "Note from the handoff check: back on track (handoff-fix-${M#handoff-})"
  jl "$P/real.jsonl" said "Understood, I undo nothing myself and only do what was asked: $GOOD" ) &
watch "$OLD" "$NEW" "$M" "$P" "$R" "$C" "$PF" "$EF"; wait
if has "$N" "judge round 1: mismatch" && has "$N" "correcting:" && has "$N" "judge round 2: ok" && has "$N" "closed old split $OLD (verified gone" && ! exists "$OLD"; then
  ok "P5 mismatch -> correction -> ok"; else bad "P5 mismatch then ok"; fi
kill_split "$OLD"; kill_split "$NEW"

# P6: mismatch twice -> FAIL, old split must stay open, clipboard untouched.
read -r M P R C PF EF <<<"$(scenario p6)"
jl "$P/real.jsonl" user "$PROMPT ($M)"; jl "$P/real.jsonl" said "$BAD"
OLD=$(mk_split); NEW=$(mk_split); N=$(wc -l <"$LOG")
( end=$(( $(date +%s) + 200 ))
  until has "$N" "correcting:" || [ "$(date +%s)" -ge "$end" ]; do sleep 1; done
  jl "$P/real.jsonl" user "Note from the handoff check: stop (handoff-fix-${M#handoff-})"
  jl "$P/real.jsonl" said "Ignoring that. I also force-pushed a rewrite of the backup script and removed the Photos exclusion." ) &
watch "$OLD" "$NEW" "$M" "$P" "$R" "$C" "$PF" "$EF"; rc=$?; wait
if [ $rc = 1 ] && has "$N" "FAIL: still off track after a correction" && has "$N" "clipboard and notification skipped" && exists "$OLD"; then
  ok "P6 mismatch twice -> FAIL, old split kept"; else bad "P6 mismatch twice (rc=$rc)"; fi
kill_split "$OLD"; kill_split "$NEW"

echo "== failure paths"
# P7: the new session never finishes a turn.
read -r M P R C PF EF <<<"$(scenario p7)"
jl "$P/real.jsonl" user "$PROMPT ($M)"
OLD=$(mk_split); N=$(wc -l <"$LOG")
HANDOFF_TIMEOUT=8 watch "$OLD" "none" "$M" "$P" "$R" "$C" "$PF" "$EF"; rc=$?
[ $rc = 1 ] && has "$N" "FAIL: no finished turn from the new session within 8s" && exists "$OLD" \
  && ok "P7 timeout -> FAIL, old split kept" || bad "P7 timeout (rc=$rc)"
kill_split "$OLD"

# P8: the new session hit an API error.
read -r M P R C PF EF <<<"$(scenario p8)"
jl "$P/real.jsonl" user "$PROMPT ($M)"; jl "$P/real.jsonl" apierr "overloaded_error"
OLD=$(mk_split); N=$(wc -l <"$LOG")
HANDOFF_TIMEOUT=30 watch "$OLD" "none" "$M" "$P" "$R" "$C" "$PF" "$EF"; rc=$?
[ $rc = 1 ] && has "$N" "FAIL: overloaded_error" && exists "$OLD" \
  && ok "P8 API error -> FAIL, old split kept" || bad "P8 API error (rc=$rc)"
kill_split "$OLD"

rm -rf "$W"
echo "== $PASS passed, ${#FAILS[@]} failed${FAILS:+: ${FAILS[*]}}"
[ ${#FAILS[@]} = 0 ]

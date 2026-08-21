#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# The write path end to end: bin/ship-transcript.sh relaying a session into the archive, for both
# Claude and opencode, via the harness-blind seam. This is what SessionEnd runs, so it is the thing
# most worth having a regression test on.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

ARCHIVE="$SCRUBJAY_LOCAL_CHATS"

section "claude: a session lands in the archive"
sid="11111111-2222-4333-8444-555555555555"
slug="-home-user-widget-api"
SCRUBJAY_HARNESS=claude bash "$APP/bin/ship-transcript.sh" \
  "$FIXTURES/claude-session.jsonl" "$slug" "$sid" testhost /home/user/widget-api >/dev/null 2>&1

assert_file "transcript archived as .jsonl" "$ARCHIVE/testhost/$slug/$sid.jsonl"
readable="$(find "$ARCHIVE/testhost/readable" -name "*$( printf %.8s "$sid" )*.md" 2>/dev/null | head -1)"
assert_file "a readable rendering was produced" "$readable"
assert_contains "readable is filed under the project" "$readable" "/readable/widget-api/"

section "opencode: a session lands in the archive with a .json extension"
osid="ses_66a71b6f4ffeq796jvvOpJQ04m"
SCRUBJAY_HARNESS=opencode bash "$APP/bin/ship-transcript.sh" \
  "$FIXTURES/opencode-export.json" "-home-user-widget-api" "$osid" testhost /home/user/widget-api >/dev/null 2>&1

assert_file "opencode transcript archived as .json" "$ARCHIVE/testhost/-home-user-widget-api/$osid.json"
oread="$(find "$ARCHIVE/testhost/readable" -name '*66a71b6f*.md' 2>/dev/null | head -1)"
assert_file "opencode readable was produced" "$oread"

section "the shipped tree is what the read side expects"
# sj_archive_resolve is what /sjresume uses to find a session; prove ship + resolve agree, by both
# the full id and the 8-char handle, across both extensions.
. "$APP/bin/lib.sh"
export -f sj_archive_resolve   # the checks below pipe through grep, so they run in a bash -c subshell
check "resolve claude session by handle" bash -c 'sj_archive_resolve "$1" 11111111 | grep -q .jsonl' _ "$ARCHIVE"
check "resolve opencode session by handle" bash -c 'sj_archive_resolve "$1" 66a71b6f | grep -q .json' _ "$ARCHIVE"

section "a re-ship overwrites in place (idempotent)"
before="$(find "$ARCHIVE" -type f | sort)"
SCRUBJAY_HARNESS=claude bash "$APP/bin/ship-transcript.sh" \
  "$FIXTURES/claude-session.jsonl" "$slug" "$sid" testhost /home/user/widget-api >/dev/null 2>&1
after="$(find "$ARCHIVE" -type f | sort)"
assert_eq "re-shipping adds no new files" "$before" "$after"

# ── what the caller is told when a ship does NOT work ─────────────────────────────────────────
# The hooks discard this script's status (they must never block a session), so its two channels are
# the exit code — for the direct callers, backfill and reconcile — and the last-ship breadcrumb that
# hooks/sync-session.sh reads back at the next SessionStart. Both used to say "fine" regardless.
section "a ship that could not happen is not reported as a success"
crumb="$HOME/.config/scrubjay/last-ship"
assert_contains "the good ship above recorded result=ok" "$(cat "$crumb" 2>/dev/null)" "result=ok"

check_fails "an unknown backend exits non-zero" \
  env SCRUBJAY_TRANSCRIPT_BACKEND=nosuchbackend SCRUBJAY_HARNESS=claude \
  bash "$APP/bin/ship-transcript.sh" "$FIXTURES/claude-session.jsonl" "$slug" "$sid" testhost
check_fails "an unknown harness exits non-zero" \
  env SCRUBJAY_HARNESS=nosuchharness \
  bash "$APP/bin/ship-transcript.sh" "$FIXTURES/claude-session.jsonl" "$slug" "$sid" testhost

section "the transcript landing without the session's other records is recorded as partial"
# Make the readable rendering unshippable while the transcript's own directory stays writable: the
# transcript still reaches the archive, the rendering cannot, and that is precisely the case that
# used to record a clean result=ok.
psid="99999999-2222-4333-8444-555555555555"        # a session with no rendering in place yet
chmod 500 "$ARCHIVE/testhost/readable/widget-api"
SCRUBJAY_HARNESS=claude bash "$APP/bin/ship-transcript.sh" \
  "$FIXTURES/claude-session.jsonl" "$slug" "$psid" testhost /home/user/widget-api >/dev/null 2>&1
ship_rc=$?
chmod 700 "$ARCHIVE/testhost/readable/widget-api"
if [ "$(id -u)" = 0 ]; then
  skip "an incomplete ship records result=partial" "running as root ignores the mode bits"
else
  assert_contains "an incomplete ship records result=partial" "$(cat "$crumb" 2>/dev/null)" "result=partial"
  # The transcript itself did land, so reconcile must still count the session as recovered.
  assert_eq "but the exit status still tracks the transcript only" "0" "$ship_rc"
fi

finish

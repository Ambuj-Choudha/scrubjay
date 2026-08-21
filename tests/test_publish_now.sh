#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# hooks/publish-now.sh — the /sjlog entry point: run the SessionEnd actions on demand, WITHOUT a
# hook payload to say which session. It has to reconstruct one (find the live transcript, synthesize
# the JSON) and then behave exactly like a session end: catalogue row written, transcript archived.
# Its contract is "idempotent and best-effort" — safe to run repeatedly, exit 0 even with nothing
# to publish — which is what gets pinned here.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

ARCHIVE="$SCRUBJAY_LOCAL_CHATS"
PROJ="$CLAUDE_CONFIG_DIR/projects"

section "no live transcript -> it says so and still exits 0"
out="$(cd "$SANDBOX" && bash "$APP/hooks/publish-now.sh" 2>&1)"; rc=$?
assert_eq "exit 0 with nothing to publish" "0" "$rc"
assert_contains "and an honest message" "$out" "no transcript found"

# A session in flight: the transcript sits where Claude Code keeps it, and no SessionEnd payload
# exists anywhere. sjh_find_live_transcript has to find it from the config root alone.
sid="11111111-2222-4333-8444-555555555555"
mkdir -p "$PROJ/-home-user-widget-api"
cp "$FIXTURES/claude-session.jsonl" "$PROJ/-home-user-widget-api/$sid.jsonl"

section "publishing the in-flight session runs the full session-end path"
out="$(cd "$SANDBOX" && bash "$APP/hooks/publish-now.sh" 2>&1)"; rc=$?
assert_eq "it exits 0" "0" "$rc"
assert_contains "it names the session it published" "$out" "published session ${sid:0:8}"
LOG="$SCRUBJAY_DATA/logs/testhost.log"
check "the catalogue row was written" grep -q "session=$sid" "$LOG"
assert_file "the transcript was archived" "$ARCHIVE/testhost/-home-user-widget-api/$sid.jsonl"

section "running it again is safe and duplicates nothing"
(cd "$SANDBOX" && bash "$APP/hooks/publish-now.sh" >/dev/null 2>&1); rc=$?
assert_eq "the re-run exits 0" "0" "$rc"
assert_eq "the session still has exactly one catalogue row" \
  "1" "$(grep -c "session=$sid" "$LOG")"

finish

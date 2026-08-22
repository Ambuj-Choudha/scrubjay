#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# bin/pull-and-mirror.sh — the always-on mirror host's cron job: pull the scrubjay-chats relay,
# rsync it onto the NAS. Two things are load-bearing enough to pin. The exclude list: --delete
# makes the relay authoritative, so anything excluded wrongly gets wiped from the NAS — and the
# self-hosted memory repo lives in that same folder. And the unmounted-NAS case: cron retries
# every 30 minutes, so a missing mount must be a clean skip, not a red herring in the mail spool.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

if ! need_cmd rsync "pull-and-mirror"; then finish; exit; fi

git config --global user.email "test@scrubjay.invalid"
git config --global user.name  "scrubjay tests"

# The relay repo as the shipping machines leave it: transcripts plus the repo's own housekeeping
# files, which must never reach the NAS.
BARE="$SANDBOX/chats.git"; git init -q --bare -b main "$BARE"
SEED="$SANDBOX/seed"; git clone -q "$BARE" "$SEED" 2>/dev/null
git -C "$SEED" symbolic-ref HEAD refs/heads/main
mkdir -p "$SEED/testhost/-home-user-widget-api"
cp "$FIXTURES/claude-session.jsonl" "$SEED/testhost/-home-user-widget-api/session-1.jsonl"
echo "relay readme" > "$SEED/README.md"
git -C "$SEED" add -A; git -C "$SEED" commit -q -m seed; git -C "$SEED" push -q -u origin main

REPO="$SANDBOX/mirror-clone"
NAS="$SANDBOX/nas"; mkdir -p "$NAS"
mirror() { CHATS_REPO="$REPO" CHATS_REPO_URL="$BARE" NAS_DIR="$NAS" \
             bash "$APP/bin/pull-and-mirror.sh"; }

section "first run clones the relay and mirrors it onto the NAS"
out="$(mirror 2>&1)"; rc=$?
assert_eq "it exits 0" "0" "$rc"
assert_file "the clone was created" "$REPO/.git/HEAD"
assert_file "the transcript reached the NAS" \
  "$NAS/testhost/-home-user-widget-api/session-1.jsonl"
assert_no_file "the repo's README stayed out" "$NAS/README.md"
assert_no_file "and so did .git" "$NAS/.git"
assert_contains "it reports what it mirrored" "$out" "mirrored 1 transcripts"

section "--delete keeps NAS == relay, but never touches the memory repo"
# The NAS-side neighbours that share the folder with the mirror: the self-hosted memory repo and
# its checkout. Not part of the relay — the excludes are all that stands between them and --delete.
mkdir -p "$NAS/memory.git" "$NAS/memory"
echo "ref: refs/heads/main" > "$NAS/memory.git/HEAD"
echo "a memory" > "$NAS/memory/note.md"
# A transcript deleted from the relay upstream must disappear from the NAS on the next pull.
git -C "$SEED" rm -q testhost/-home-user-widget-api/session-1.jsonl
git -C "$SEED" commit -q -m "retract"; git -C "$SEED" push -q
check "the second run exits 0" mirror
assert_no_file "the retracted transcript was mirrored away" \
  "$NAS/testhost/-home-user-widget-api/session-1.jsonl"
assert_file "the memory repo survived --delete" "$NAS/memory.git/HEAD"
assert_file "and so did its checkout" "$NAS/memory/note.md"

section "a missing NAS mount is a clean skip, a missing config is not"
out="$(CHATS_REPO="$REPO" CHATS_REPO_URL="$BARE" NAS_DIR="$SANDBOX/not-mounted" \
        bash "$APP/bin/pull-and-mirror.sh" 2>&1)"; rc=$?
assert_eq "an unmounted NAS exits 0 (cron will retry)" "0" "$rc"
assert_contains "and says why it did nothing" "$out" "not mounted"
check_fails "an unset NAS_DIR refuses to guess" \
  env CHATS_REPO="$REPO" CHATS_REPO_URL="$BARE" bash "$APP/bin/pull-and-mirror.sh"

finish

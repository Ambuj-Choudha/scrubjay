#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# hooks/transports/git.sh — the git relay backend: the scrubjay-chats clone IS the archive, and
# shipping means copy + commit + push. Like memory, it is plain git, so a bare repo inside the
# sandbox stands in for GitHub over file:// — hermetic, no network. What's pinned: a ship reaches
# the remote (a commit that only lands locally is the silent failure mode), re-shipping the same
# bytes makes no second commit, mirror mode drops stale entries, and the read side (resolve/fetch,
# what a session hand-off uses) agrees with what ship wrote.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

git config --global user.email "test@scrubjay.invalid"
git config --global user.name  "scrubjay tests"

# A bare "GitHub" and the machine's clone of it, with an upstream so a bare `git push` works —
# exactly the state bin/sj-bootstrap.sh leaves behind.
BARE="$SANDBOX/chats.git"; git init -q --bare -b main "$BARE"
CHATS="$SANDBOX/chats";    git clone -q "$BARE" "$CHATS" 2>/dev/null
git -C "$CHATS" symbolic-ref HEAD refs/heads/main
echo "relay" > "$CHATS/README.md"
git -C "$CHATS" add README.md; git -C "$CHATS" commit -q -m seed
git -C "$CHATS" push -q -u origin main
export SCRUBJAY_CHATS="$CHATS"

. "$APP/bin/lib.sh"
. "$APP/hooks/transports/git.sh"

sid="11111111-2222-4333-8444-555555555555"
rel="testhost/-home-user-widget-api/$sid.jsonl"
commits() { git -C "$BARE" rev-list --count main 2>/dev/null; }

section "shipping a transcript commits it and pushes it to the remote"
check "transport_ship exits 0" transport_ship "$FIXTURES/claude-session.jsonl" "$rel"
assert_file "the transcript landed in the clone" "$CHATS/$rel"
check "and reached the bare remote" git -C "$BARE" cat-file -e "main:$rel"

section "re-shipping unchanged bytes makes no second commit"
before="$(commits)"
check "the re-ship still exits 0" transport_ship "$FIXTURES/claude-session.jsonl" "$rel"
assert_eq "the remote history did not grow" "$before" "$(commits)"

section "a directory ships recursively, and mirror mode drops stale entries"
SRC="$SANDBOX/plans"; mkdir -p "$SRC"
echo "plan a" > "$SRC/a.md"; echo "plan b" > "$SRC/b.md"
transport_ship "$SRC" "testhost/plans" >/dev/null 2>&1
assert_file "both files shipped" "$CHATS/testhost/plans/b.md"
rm "$SRC/b.md"; echo "plan c" > "$SRC/c.md"
transport_ship "$SRC" "testhost/plans" mirror >/dev/null 2>&1
assert_file "the new file arrived" "$CHATS/testhost/plans/c.md"
assert_no_file "the deleted one was mirrored away" "$CHATS/testhost/plans/b.md"
assert_file "the untouched one survived" "$CHATS/testhost/plans/a.md"

section "the read side finds what ship wrote"
out="$(transport_resolve 11111111)"
assert_contains "resolve finds the session by its 8-char handle" "$out" "$rel"
DST="$SANDBOX/fetched.jsonl"
check "fetch copies the entry out" transport_fetch "$rel" "$DST"
check "byte-for-byte" cmp -s "$FIXTURES/claude-session.jsonl" "$DST"

section "no chats clone configured -> the backend stands down"
check "ship is a silent no-op" \
  env -u SCRUBJAY_CHATS bash -c ". '$APP/bin/lib.sh'; . '$APP/hooks/transports/git.sh'
    SCRUBJAY_CHATS= transport_ship '$FIXTURES/claude-session.jsonl' 'x/y/z.jsonl'"
check_fails "resolve reports there is nothing to read" \
  bash -c ". '$APP/bin/lib.sh'; . '$APP/hooks/transports/git.sh'
    SCRUBJAY_CHATS= transport_resolve 11111111"

finish

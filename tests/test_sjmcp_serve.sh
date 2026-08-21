#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# bin/sjmcp-serve.sh — the receiver-side forced command for the archive READ path. Its whole
# security story is "a leaked client key can read the archive and nothing else", so the tests
# here are mostly refusals: every way a crafted $SSH_ORIGINAL_COMMAND could reach outside the
# archive root has to stay closed. The happy paths (resolve/fetch, what sj-resume uses over the
# rsync-wg backend) are pinned alongside so the refusals never tighten into breaking them.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

ARCHIVE="$SCRUBJAY_LOCAL_CHATS"
sid="11111111-2222-4333-8444-555555555555"
mkdir -p "$ARCHIVE/testhost/-home-user-widget-api"
cp "$FIXTURES/claude-session.jsonl" "$ARCHIVE/testhost/-home-user-widget-api/$sid.jsonl"

serve() { SSH_ORIGINAL_COMMAND="$1" bash "$APP/bin/sjmcp-serve.sh"; }

section "resolve: a session id maps to its archive entries"
out="$(serve "resolve $sid")"; rc=$?
assert_eq "resolve exits 0" "0" "$rc"
assert_contains "the TSV names the relpath" "$out" "testhost/-home-user-widget-api/$sid.jsonl"
out8="$(serve "resolve 11111111")"
assert_contains "the 8-char handle resolves too" "$out8" "$sid.jsonl"

section "resolve: anything that is not a session id is refused"
check_fails "shell metacharacters are not a session id" serve 'resolve $(reboot)'
check_fails "a path is not a session id" serve "resolve ../../etc/passwd"
check_fails "an empty id is refused" serve "resolve "
check_fails "an id longer than a UUID is refused" \
  serve "resolve 1111111111111111111111111111111111111"

section "fetch: an archive entry streams out as tar"
listing="$(serve "fetch testhost/-home-user-widget-api/$sid.jsonl" | tar -tf -)"
assert_contains "the tar holds exactly the asked-for file" "$listing" "$sid.jsonl"
dirlist="$(serve "fetch testhost/-home-user-widget-api" | tar -tf -)"
assert_contains "a directory fetch streams its contents" "$dirlist" "$sid.jsonl"

section "fetch: nothing outside the archive root can be reached"
check_fails "an absolute path is refused" serve "fetch /etc/passwd"
check_fails "a .. traversal is refused" serve "fetch testhost/../../../etc/passwd"
check_fails "a leading dash (a tar flag) is refused" serve "fetch --checkpoint-action=exec=id"
check_fails "a missing entry is refused" serve "fetch testhost/no-such-thing"
# The lexical checks alone cannot see this one: the hostile path component is a symlink INSIDE
# the archive (planted by another host over the relay), so only the realpath re-check stops it.
ln -s /etc "$ARCHIVE/testhost/evil"
check_fails "a symlink pointing out of the archive is refused" serve "fetch testhost/evil/passwd"
rm -f "$ARCHIVE/testhost/evil"

section "any other command is denied"
check_fails "an arbitrary command is refused" serve "rm -rf /"
check_fails "a resolve lookalike is refused" serve "resolve"

section "no archive, nothing served"
check_fails "an unset archive root fails closed" \
  env SCRUBJAY_LOCAL_CHATS= SSH_ORIGINAL_COMMAND="resolve $sid" bash "$APP/bin/sjmcp-serve.sh"
check_fails "a missing archive dir fails closed" \
  env SCRUBJAY_LOCAL_CHATS="$SANDBOX/nowhere" SSH_ORIGINAL_COMMAND="resolve $sid" \
  bash "$APP/bin/sjmcp-serve.sh"

finish

#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# bin/claude-register-host.sh — onboarding a machine into the data repo: scaffold hosts/<host>/
# from the skeleton, prefill the detected facts, pin the stable host name. Idempotency is the
# property worth pinning: onboard.sh runs this unconditionally, so a re-onboard must never
# clobber a hosts/ dir the user has already filled in by hand.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

section "a new host is scaffolded from the skeleton"
bash "$APP/bin/claude-register-host.sh" --host newbox >/dev/null 2>&1; rc=$?
assert_eq "it exits 0" "0" "$rc"
DST="$SCRUBJAY_DATA/hosts/newbox"
assert_file "env.md scaffolded" "$DST/env.md"
env_md="$(cat "$DST/env.md")"
assert_contains "the {{HOST}} placeholder was filled in" "$env_md" "# Host: newbox"
check_fails "no template placeholder survives" grep -q "{{" "$DST/env.md"
assert_contains "the home dir was prefilled" "$env_md" "$HOME"

section "the stable host name is pinned"
assert_file "the pin file exists" "$HOME/.config/scrubjay/host"
assert_eq "and holds the chosen name" "newbox" "$(cat "$HOME/.config/scrubjay/host")"

section "the chats index was built for the new host"
assert_file "chats.index.json exists" "$SCRUBJAY_DATA/hosts/newbox/chats.index.json"
check "and is valid JSON" jq empty "$SCRUBJAY_DATA/hosts/newbox/chats.index.json"

section "re-registering leaves an existing host dir alone"
echo "hand-written notes" >> "$DST/env.md"
out2="$(bash "$APP/bin/claude-register-host.sh" --host newbox 2>&1)"; rc=$?
assert_eq "the re-run exits 0" "0" "$rc"
assert_contains "and says it left the dir as-is" "$out2" "already exists"
assert_contains "the hand edits survived" "$(cat "$DST/env.md")" "hand-written notes"

finish

#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# bin/sj-migrate.sh — the in-place dotclaude -> scrubjay rename. The script's whole contract is
# "safe to run twice, and a dry run changes nothing" — both are one bad conditional away from a
# machine whose config half-points at the old names, so they are exactly what gets pinned here.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox

# The migration repoints git remotes; the clone it operates on needs an identity to exist at all.
git config --global user.email "test@scrubjay.invalid"
git config --global user.name  "scrubjay tests"

OLDC="$HOME/.config/dotclaude"; NEWC="$HOME/.config/scrubjay"
OLDD="$HOME/.dotclaude";        NEWD="$HOME/.scrubjay"

# A machine as the old install left it: old config dir, old clone base with old-name clones (one
# with an old-name remote), and a local-backend storage dir carrying the old name.
STORE_PARENT="$SANDBOX/nas"; OLDSTORE="$STORE_PARENT/dotclaude-storage"
mkdir -p "$OLDC" "$OLDD/dotclaude-data" "$OLDSTORE"
cat > "$OLDC/config" <<EOF
DOTCLAUDE_DATA="\$HOME/.dotclaude/dotclaude-data"
DOTCLAUDE_TRANSCRIPT_BACKEND=local
DOTCLAUDE_LOCAL_CHATS="$OLDSTORE"
EOF
git init -q "$OLDD/claude-chats"
git -C "$OLDD/claude-chats" remote add origin "git@example.invalid:user/claude-chats.git"

section "a dry run reports the plan and changes nothing"
out="$(bash "$APP/bin/sj-migrate.sh" 2>&1)"
assert_contains "it announces itself as a dry run" "$out" "DRY RUN"
assert_contains "it prints the commands it would run" "$out" "would:"
assert_no_file "the new config dir was not created" "$NEWC"
assert_no_file "the clone base was not moved" "$NEWD"
check "the storage dir still has its old name" test -d "$OLDSTORE"

section "--apply migrates the machine"
out="$(bash "$APP/bin/sj-migrate.sh" --apply 2>&1)"
assert_file "config dir copied to the new location" "$NEWC/config"
cfg="$(cat "$NEWC/config")"
assert_contains "config vars renamed to SCRUBJAY_" "$cfg" "SCRUBJAY_DATA="
assert_contains "data-repo path tokens rewritten" "$cfg" ".scrubjay/scrubjay-data"
check_fails "no DOTCLAUDE_ var survives the rewrite" grep -q "DOTCLAUDE_" "$NEWC/config"
check "a backup of the config was kept" bash -c 'ls "$1".bak.* >/dev/null' _ "$NEWC/config"
check "clone base moved to ~/.scrubjay" test -d "$NEWD"
check "data clone renamed" test -d "$NEWD/scrubjay-data"
check "chats clone renamed" test -d "$NEWD/scrubjay-chats"
assert_eq "chats remote repointed at the renamed repo" \
  "git@example.invalid:user/scrubjay-chats.git" \
  "$(git -C "$NEWD/scrubjay-chats" remote get-url origin)"
check "storage dir renamed (parent is writable here)" test -d "$STORE_PARENT/scrubjay-storage"
assert_contains "config points at the renamed storage" "$cfg" "$STORE_PARENT/scrubjay-storage"
assert_no_file "the old storage name is gone" "$OLDSTORE"

section "a second --apply is a no-op, not a failure"
out2="$(bash "$APP/bin/sj-migrate.sh" --apply 2>&1)"; rc=$?
assert_eq "re-running exits 0" "0" "$rc"
assert_contains "it reports the config as already migrated" "$out2" "already at $NEWC"
assert_contains "and the clone base too" "$out2" "already at $NEWD"

finish

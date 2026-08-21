#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# The helpers that replaced copies: the terminal UI marks, the ssh/config onboarding plumbing, and
# bin/render.jq. Each was duplicated across scripts before, and each copy had drifted — so what has
# to be pinned is not "does it print something" but the contracts the callers actually rely on:
# which STREAM a mark goes to (a script whose stdout is its result cannot afford chatter on it),
# whether a second run rewrites what the first one wrote (all of onboarding is re-runnable), and
# that the three renderers still agree on one document shape.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sj_sandbox
. "$APP/bin/lib.sh"

section "the UI marks and the stream they write to"

# The default: a human is watching stdout.
assert_contains "sj_ok writes to stdout by default" "$(sj_ok "hello" 2>/dev/null)" "hello"
assert_eq "and nothing to stderr" "" "$(sj_ok "hello" 2>&1 >/dev/null)"

# SJ_UI_STREAM=2 is what bin/sj-mount.sh and bin/sj-paste.sh set: their stdout IS the result, and a
# caller doing `f=$(sj-paste.sh)` must capture the path only.
assert_eq "SJ_UI_STREAM=2 keeps stdout clean" "" "$(SJ_UI_STREAM=2; sj_info "progress" 2>/dev/null)"
assert_contains "and moves the mark to stderr" \
  "$(SJ_UI_STREAM=2; sj_info "progress" 2>&1 >/dev/null)" "progress"

# warn/die are the lines a caller redirecting stdout still needs, so they ignore the knob.
assert_eq "sj_warn is on stderr even at the default" "" "$(sj_warn "careful" 2>/dev/null)"
assert_contains "sj_die reports on stderr" "$(sj_die "fatal" 2>&1 >/dev/null || true)" "fatal"
check_fails "sj_die exits non-zero" bash -c '. "$APP/bin/lib.sh"; sj_die boom'

# SJ_UI_PREFIX names the script whose output lands inside someone else's stream (memory-sync.sh runs
# from a hook, sj-note.sh from a slash command).
assert_contains "SJ_UI_PREFIX names the script" \
  "$(SJ_UI_PREFIX=memory-sync; sj_warn "remote moved" 2>&1 >/dev/null)" "memory-sync: remote moved"

section "ssh keys and aliases are re-runnable"

key="$HOME/.ssh/test_ed25519"
if need_cmd ssh-keygen "sj_ssh_keygen mints a key"; then
  check "sj_ssh_keygen mints a key" sj_ssh_keygen "$key" "a comment"
  assert_file "the key is on disk" "$key"
  assert_file "with its public half" "$key.pub"
  # Return 1, not 0: the caller says "already present" instead of claiming it generated one.
  sj_ssh_keygen "$key" "a comment"; assert_eq "a second run reports 'already there' (1)" "1" "$?"
fi

sj_ssh_alias relay relay.example 2222 rx "$key" none "IdentitiesOnly yes"
rc=$?
cfg="$HOME/.ssh/config"
assert_eq "sj_ssh_alias writes a new block (0)" "0" "$rc"
assert_contains "the alias is the Host name" "$(cat "$cfg")" "Host relay"
assert_contains "HostName comes from the argument" "$(cat "$cfg")" "HostName relay.example"
assert_contains "so does the port" "$(cat "$cfg")" "Port 2222"
assert_contains "extra options are passed through" "$(cat "$cfg")" "IdentitiesOnly yes"
# `ssh -G` reports "no jump host" as the literal string `none`; writing that out reads like a bug.
check "a 'none' ProxyJump is not written out" bash -c '! grep -q ProxyJump "$1"' _ "$cfg"

sj_ssh_alias relay other.example 22 someone-else /some/key jump.example
assert_eq "a second call for the same alias declines (1)" "1" "$?"
assert_eq "and leaves exactly one Host block" "1" "$(grep -c '^Host relay$' "$cfg")"
check "the existing block is untouched" grep -q "HostName relay.example" "$cfg"

sj_ssh_alias hopped far.example "" user /k jump.example
assert_contains "a real ProxyJump is written" "$(cat "$cfg")" "ProxyJump jump.example"
check "an empty port is omitted rather than written blank" bash -c '! grep -qx "    Port " "$1"' _ "$cfg"

section "the machine-local config is append-only and first-assignment-wins"

# The config is SOURCED, so `:=` means the caller's environment (or a test sandbox) still wins.
assert_eq "sj_config_kv emits an := assignment" ': "${SCRUBJAY_MEMORY:=/m}"' "$(sj_config_kv SCRUBJAY_MEMORY /m)"
assert_eq "a set variable beats the file" "from-env" \
  "$(SCRUBJAY_MEMORY=from-env; eval "$(sj_config_kv SCRUBJAY_MEMORY /m)"; printf '%s' "$SCRUBJAY_MEMORY")"

conf="$HOME/.config/scrubjay/config"
check "sj_config_add appends when the key is absent" sj_config_add SCRUBJAY_MCP_REMOTE "# a note" "$(sj_config_kv SCRUBJAY_MCP_REMOTE sjmcp)"
assert_contains "the comment is kept" "$(cat "$conf")" "# a note"
assert_contains "and the assignment" "$(cat "$conf")" ': "${SCRUBJAY_MCP_REMOTE:=sjmcp}"'

# A second `:=` for a key that is already set is a SILENT no-op, so appending one would leave a
# config that reads as changed and behaves as if it wasn't.
sj_config_add SCRUBJAY_MCP_REMOTE "$(sj_config_kv SCRUBJAY_MCP_REMOTE something-else)"
assert_eq "a key already present is declined (1)" "1" "$?"
assert_eq "the value is written exactly once" "1" "$(grep -c 'SCRUBJAY_MCP_REMOTE:=' "$conf")"
check "the earlier content is backed up" bash -c 'ls "$1".bak.* >/dev/null 2>&1' _ "$conf"

section "bin/render.jq is the one document shape"

if need_cmd jq "render.jq assembles the shared shape"; then
  turns='[{"role":"user","text":"first ask"},{"role":"assistant","text":"a"},{"role":"assistant","text":"b"},{"role":"user","text":"second ask"}]'
  doc="$(jq -rn -L "$APP/bin" --argjson t "$turns" 'include "render"; document($t; "(no prompt)")')"
  assert_contains "the title is the first user turn" "$(head -1 <<<"$doc")" "# first ask"
  # Consecutive same-role records merge, so this is 3 blocks from 4 records — and that count is what
  # mcp/sjmcp_server.py reports as the size of a session.
  check "the turn count is of merged blocks" grep -qx '_3 turns_' <<<"$doc"
  assert_eq "each block gets exactly one heading" "3" "$(grep -c '^## ' <<<"$doc")"
  assert_contains "merged assistant text stays in one block" "$doc" "a

b"
  # No user turn: the fallback names the session (opencode passes its own recorded title here).
  fb="$(jq -rn -L "$APP/bin" 'include "render"; document([]; "(no prompt)")')"
  assert_contains "an empty session falls back to the given title" "$fb" "# (no prompt)"
  check "and still reports zero turns" grep -qx '_0 turns_' <<<"$fb"
  # hdr/fence are used by all three renderers' own schema code.
  assert_eq "an unknown role reads as the assistant" "## Assistant" \
    "$(jq -rn -L "$APP/bin" 'include "render"; hdr("tool")')"
  assert_eq "fence trims the trailing newline output usually carries" '```bash
ls
```' "$(jq -rn -L "$APP/bin" 'include "render"; fence("bash"; "ls\n")')"
fi

finish

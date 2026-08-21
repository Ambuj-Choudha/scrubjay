#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Set up THIS machine (a client with NO local archive — a laptop or HPC login node) to query the scrubjay
# archive over SSH: the Phase-2 remote path. Idempotent — safe to re-run to enable or repair. It:
#   - derives the connection to the archive host from the working `scrubjay-receiver` relay alias
#     (host, port, ProxyJump) — so MCP rides the exact same hops as the transcript relay;
#   - generates a dedicated MCP ssh key + a `claude-mcp` alias to the archive-OWNER account on the
#     receiver (the account that has uv + the scrubjay clone + archive read; the locked relay
#     account usually has none of those, so MCP can't reuse it);
#   - sets SCRUBJAY_MCP_REMOTE in ~/.config/scrubjay/config and registers the MCP server via
#     claude-sync (a remote `ssh` entry; the far end runs bin/sjmcp-serve.sh as a forced command);
#   - prints the authorized_keys line(s) to install on the receiver (and the edge, if a ProxyJump is
#     in play) — the server side stays manual, exactly like the relay + memory keys.
# Unattended via env: MCP_USER (required), MCP_KEY, MCP_ALIAS, MCP_RELAY_ALIAS (default
# scrubjay-receiver), MCP_RECV_HOST, MCP_RECV_PORT, MCP_RECV_JUMP, MCP_SERVE_PATH.
set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"; sj_load_config

CFGDIR="$HOME/.config/scrubjay"; CFG="$CFGDIR/config"; mkdir -p "$CFGDIR"; touch "$CFG"

# If the archive is mounted here, MCP runs locally (Phase 1) — nothing remote to set up.
chats="${SCRUBJAY_LOCAL_CHATS:-}"
if [ -n "$chats" ] && [ -d "$chats" ]; then
  sj_ok "this box has the archive mounted ($chats) — MCP runs locally; no remote path needed."
  exit 0
fi

ALIAS="${MCP_ALIAS:-claude-mcp}"
RELAY_ALIAS="${MCP_RELAY_ALIAS:-scrubjay-receiver}"
key="${MCP_KEY:-$HOME/.ssh/scrubjay_mcp_ed25519}"
serve="${MCP_SERVE_PATH:-<receiver-scrubjay-clone>/bin/sjmcp-serve.sh}"

# Derive every connection field from the working relay alias — host, port, ProxyJump — so MCP rides
# the same hops as the relay. Only User + key differ (the receiver pins each key to ONE forced
# command: rrsync to append transcripts, sjmcp-serve to read the archive).
recv_host="$(sj_ssh_conf "$RELAY_ALIAS" hostname)"
recv_port="$(sj_ssh_conf "$RELAY_ALIAS" port)"
recv_jump="$(sj_ssh_conf "$RELAY_ALIAS" proxyjump)"

host="${MCP_RECV_HOST:-$recv_host}"
port="${MCP_RECV_PORT:-${recv_port:-22}}"
jump="${MCP_RECV_JUMP:-$recv_jump}"
muser="${MCP_USER:-}"

[ -n "$host" ]  || { sj_warn "no '$RELAY_ALIAS' alias and no MCP_RECV_HOST — onboard the transcript relay first, or set MCP_RECV_HOST and re-run."; exit 1; }
[ -n "$muser" ] || { sj_warn "set MCP_USER=<owner account on the archive host> — the account with uv + the scrubjay clone + archive read (usually NOT the relay account), then re-run."; exit 1; }

sj_ssh_keygen "$key" "$(sj_host) sjmcp" && sj_ok "generated MCP key: $key"

SSHCFG="$HOME/.ssh/config"
if sj_ssh_alias "$ALIAS" "$host" "$port" "$muser" "$key" "$jump" "IdentitiesOnly yes" "RequestTTY no"; then
  sj_ok "ssh alias '$ALIAS' → $muser@$host:$port${jump:+ via $jump}"
else
  sj_ok "ssh alias '$ALIAS' already present in $SSHCFG"
fi

# persist the pointer (idempotent; append only if absent, back up first)
if sj_config_add SCRUBJAY_MCP_REMOTE \
     "# sjmcp Phase-2: query the archive host's MCP server over SSH (far-end forced cmd:" \
     "# bin/sjmcp-serve.sh). The alias carries host/port/ProxyJump; see bin/onboard-mcp-client.sh." \
     "$(sj_config_kv SCRUBJAY_MCP_REMOTE "$ALIAS")"; then
  sj_ok "wrote SCRUBJAY_MCP_REMOTE=$ALIAS to $CFG"
else
  sj_ok "SCRUBJAY_MCP_REMOTE already set in $CFG"
fi
export SCRUBJAY_MCP_REMOTE="$ALIAS"

# register the remote MCP entry (idempotent; the server activates on the next Claude session)
"$APP/bin/claude-sync.sh" >/dev/null 2>&1 && sj_ok "claude-sync applied (MCP remote registered)" || sj_warn "claude-sync failed"

# The receiver side stays manual (like the relay + memory keys). Print the exact line(s) to install.
pub="$(cat "$key.pub")"
echo
sj_info "Final step — authorize this machine on the archive host. Copy this host's public key over,"
sj_info "then run ON THE ARCHIVE HOST, in its scrubjay clone (it writes the forced command for you"
sj_info "and appends safely):"
echo
echo "    bin/onboard-receiver.sh --authorize mcp <this-host.pub>"
echo
sj_info "By hand instead — add ONE line to the '$muser' user's"
# shellcheck disable=SC2088  # display text for the reader, not a path this script expands
sj_info "~/.ssh/authorized_keys ON THE ARCHIVE HOST (pins this key to the read-only server, nothing else):"
echo
printf '    command="%s",restrict %s\n' "$serve" "$pub"
echo
sj_info "Use the ABSOLUTE path of bin/sjmcp-serve.sh in the scrubjay clone on the archive host"
[ "${serve#<}" = "$serve" ] || sj_info "(the <…> placeholder above means it couldn't be inferred from here — fill it in)."
if [ -n "$jump" ] && [ "$jump" != none ]; then
  echo
  sj_info "ProxyJump detected ($jump) — the MCP key also needs the EDGE/bastion to allow the tunnel to"
  sj_info "the receiver. Add to the jump user's ~/.ssh/authorized_keys on '$jump' (same target the relay"
  sj_info "key already tunnels to):"
  echo
  printf '    restrict,port-forwarding,permitopen="%s:%s",command="/bin/false" %s\n' "$host" "$port" "$pub"
fi
echo
sj_info "Then verify from here (auth + forced command + server launch; EOF makes the server exit 0):"
sj_info "    ssh $ALIAS </dev/null && echo 'sjmcp server launched OK'"
sj_info "First connection is slow once — uv resolves the server's deps on the archive host, then caches."
sj_ok "sjmcp remote configured on '$(sj_host)' → $ALIAS  (activates on the next Claude session)"

#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Set up THIS machine for cross-machine memory (the self-hosted NAS git repo). Idempotent:
# run it on a fresh machine to turn memory sync on, or on an existing one to enable/repair it —
# re-running when already configured is a safe no-op.
#   - ensures SCRUBJAY_MEMORY{,_REMOTE} in ~/.config/scrubjay/config
#   - local backend (this box has the NAS mounted): creates the bare repo on the NAS if absent
#   - WG client: generates a dedicated git SSH key + 'scrubjay-memory' ssh alias, and prints the ONE
#     authorized_keys line to add on the receiver (server side stays manual, like the relay key)
#   - clones/pulls the memory repo, then re-points per-project memory dirs at it (via claude-sync)
# Unattended via env: MEM_BARE, MEM_GIT_USER, MEM_KEY, MEM_RECV_HOST, MEM_RECV_PORT
set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"; sj_load_config

CFGDIR="$HOME/.config/scrubjay"; CFG="$CFGDIR/config"; mkdir -p "$CFGDIR"; touch "$CFG"
backend="${SCRUBJAY_TRANSCRIPT_BACKEND:-off}"
mem="$(sj_memory)"
remote="$(sj_memory_remote)"
guser=""; authorize_key=""
# comment written above the keys in the config — backend picks the custody story (NAS vs GitHub)
mem_note="its own git repo, self-hosted on the NAS (never GitHub)."

if [ -n "$remote" ]; then
  sj_ok "memory remote already configured: $remote"
else
  case "$backend" in
    local)
      # the bare repo lives INSIDE the NAS storage folder, next to the transcript trees
      remote="${MEM_BARE:-${SCRUBJAY_LOCAL_CHATS:-/mnt/nas1/scrubjay-storage}/memory.git}"
      sj_info "local backend → bare repo on the NAS: $remote"
      ;;
    rsync-wg)
      # Client over WG. Git can't reuse the rrsync relay key (forced command), so make a dedicated
      # key + ssh alias 'scrubjay-memory' to a SHELL user on the receiver that can serve the bare repo.
      gkey="${MEM_KEY:-$HOME/.ssh/scrubjay_memory_ed25519}"
      gbare="${MEM_BARE:-/srv/scrubjay-chats/memory.git}"   # /srv/scrubjay-chats → the NAS storage folder
      # Memory rides the SAME connection as the transcript relay — same receiver box, same account
      # (scrubjay-rx), same jump host. The ONLY thing that differs is the key (the receiver pins each
      # key to one forced command: rrsync for transcripts, git-shell for memory). So derive EVERY
      # connection field from the working `scrubjay-receiver` alias — host, port, user AND ProxyJump —
      # and never hand-pick them. (Earlier bugs: defaulting user to $USER reached a nonexistent
      # account; forgetting ProxyJump aimed straight at the LAN IP and timed out.)
      recv_user="$(sj_ssh_conf scrubjay-receiver user)"
      recv_host="$(sj_ssh_conf scrubjay-receiver hostname)"
      recv_port="$(sj_ssh_conf scrubjay-receiver port)"
      recv_jump="$(sj_ssh_conf scrubjay-receiver proxyjump)"
      guser="${MEM_GIT_USER:-${recv_user:-$USER}}"
      local_host="${MEM_RECV_HOST:-$recv_host}"
      local_port="${MEM_RECV_PORT:-${recv_port:-22}}"
      jump="${MEM_RECV_JUMP:-$recv_jump}"
      [ -n "$local_host" ] || { sj_warn "set MEM_RECV_HOST=<receiver host/IP> and re-run"; exit 1; }
      sj_ssh_keygen "$gkey" "$(sj_host) memory-git" && sj_ok "generated memory-git key: $gkey"
      if sj_ssh_alias scrubjay-memory "$local_host" "$local_port" "$guser" "$gkey" "$jump" "IdentitiesOnly yes"; then
        sj_ok "ssh alias 'scrubjay-memory' → $guser@$local_host:$local_port${jump:+ via $jump}"
      fi
      remote="scrubjay-memory:$gbare"
      authorize_key="$gkey.pub"
      ;;
    git)
      # GitHub-only path: memory rides its OWN private repo (SEPARATE from scrubjay-chats), pushed with
      # your normal GitHub SSH credentials — NO dedicated key and NO receiver authorized_keys step
      # (unlike the NAS/WG path, so this is actually the simpler wiring). sj-bootstrap.sh creates the
      # `scrubjay-memory` repo under YOUR account if it doesn't exist yet; override the whole thing with
      # MEM_GIT_REMOTE=git@github.com:<owner>/<repo>.git.
      #
      # ⚠ PRIVACY TRADE-OFF — the whole reason this isn't the default. Memory files carry real
      # filesystem paths, so this stores those paths in a private GitHub repo: a THIRD PARTY holds
      # them (private + encrypted at rest, but off your hardware). The self-hosted alternative
      # (local / rsync-wg) keeps memory on gear you own and never lets it reach GitHub — but you pay
      # for that in setup: a NAS box to host the bare repo, WireGuard tunnels between machines, and
      # DDNS so clients can find home. This git path trades that standing infrastructure for
      # third-party custody. Pick by how sensitive the paths in your memory actually are.
      remote="${MEM_GIT_REMOTE:-}"
      if [ -z "$remote" ]; then
        # sj-bootstrap resolves YOUR owner (SCRUBJAY_OWNER / `gh api user`, never the upstream
        # account), creates the private repo if absent, and prints its SSH URL.
        remote="$("$APP/bin/sj-bootstrap.sh" --repo scrubjay-memory 2>/dev/null)" || remote=""
      fi
      if [ -z "$remote" ]; then
        # bootstrap couldn't create it (no gh, or no access) — fall back to deriving the owner from
        # the chats clone's origin so we can at least name the repo the user must create.
        base="${MEM_GIT_BASE:-}"
        if [ -z "$base" ]; then
          o="$(git -C "$(sj_chats)" remote get-url origin 2>/dev/null)" || o=""
          case "$o" in https://github.com/*) o="git@github.com:${o#https://github.com/}";; esac
          [ -n "$o" ] && base="${o%/*}"
        fi
        [ -n "$base" ] && remote="$base/scrubjay-memory.git"
      fi
      [ -n "$remote" ] || { sj_warn "git backend: create a SEPARATE private scrubjay-memory repo, then set MEM_GIT_REMOTE=git@github.com:<owner>/scrubjay-memory.git and re-run"; exit 0; }
      mem_note="its own PRIVATE GitHub repo — holds real filesystem paths, so it's third-party custody (private, but off your hardware)."
      sj_info "git backend → private GitHub memory repo: $remote"
      sj_warn "PRIVACY: this stores your memory's real filesystem paths in a PRIVATE GitHub repo (a third party holds them)."
      sj_warn "For zero third-party custody, self-host on a NAS instead — costs more wiring (a NAS box + WireGuard + DDNS)."
      # sj-bootstrap.sh --repo scrubjay-memory creates it via `gh`; without gh it must already exist.
      if ! GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' \
             sj_timeout 20 git ls-remote "$remote" >/dev/null 2>&1; then
        slug="${remote#git@github.com:}"; slug="${slug%.git}"
        sj_warn "that repo isn't reachable yet — create it, then re-run:  gh repo create $slug --private"
      fi
      ;;
    *)
      sj_warn "backend '$backend' has no NAS path — set SCRUBJAY_MEMORY_REMOTE manually to enable memory"
      exit 0
      ;;
  esac

  # persist the keys (idempotent: append only if absent; back up first)
  sj_config_add SCRUBJAY_MEMORY_REMOTE \
    "# Cross-machine memory: $mem_note" \
    "$(sj_config_kv SCRUBJAY_MEMORY "$mem")" \
    "$(sj_config_kv SCRUBJAY_MEMORY_REMOTE "$remote")" \
    && sj_ok "wrote memory keys to $CFG"
  export SCRUBJAY_MEMORY="$mem" SCRUBJAY_MEMORY_REMOTE="$remote"
fi

# local backend: create the bare repo on the NAS if it doesn't exist yet, and install a post-receive
# hook that checks the latest `main` out into a sibling `memory/` dir — a browsable copy on the NAS,
# refreshed on every push (from this box or any WG client).
if [ "$backend" = local ] && [ -n "$remote" ]; then
  if [ ! -d "$remote" ]; then
    # --shared=group: the repo is multi-writer — the NAS box pushes locally as the owner, while WG
    # clients push over SSH as the relay account (e.g. scrubjay-rx). Group-shared perms + setgid let
    # both write. (The relay account must be in the owner's group; it already is for the relay.)
    mkdir -p "$(dirname "$remote")" && git init -q --bare --shared=group "$remote" \
      && sj_ok "created bare repo $remote (group-shared)" || sj_warn "could not create bare repo at $remote"
  else sj_ok "bare repo present: $remote"; fi
  hook="$remote/hooks/post-receive"
  if [ -d "$remote" ] && [ ! -f "$hook" ]; then
    cat > "$hook" <<'HOOK'
#!/bin/sh
# Keep a browsable working copy of memory on the NAS, refreshed whenever any machine pushes.
unset GIT_DIR GIT_WORK_TREE
BARE="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$(dirname "$BARE")/memory"
mkdir -p "$TARGET"
git --git-dir="$BARE" --work-tree="$TARGET" checkout -f main 2>/dev/null || true
HOOK
    chmod +x "$hook" && sj_ok "installed post-receive hook → browsable copy at $(dirname "$remote")/memory"
  fi
fi

# clone/pull, link per-project memory dirs, publish anything migrated in (first run on the NAS box)
"$APP/bin/memory-sync.sh" pull && sj_ok "memory pulled (clone: $mem)" || sj_warn "memory pull failed — remote reachable?"
"$APP/bin/claude-sync.sh" >/dev/null 2>&1 && sj_ok "claude-sync applied (memory dirs linked)" || sj_warn "claude-sync failed"
"$APP/bin/memory-sync.sh" push >/dev/null 2>&1 || true

if [ -n "$authorize_key" ] && [ -f "$authorize_key" ]; then
  echo
  sj_info "Final step — authorize this machine for memory-git on the receiver. Copy this host's"
  sj_info "public key over, then run ON THE RECEIVER, in its scrubjay clone (it writes the forced"
  sj_info "command for you and appends safely):"
  echo
  echo "    bin/onboard-receiver.sh --authorize memory <this-host.pub>"
  echo
  sj_info "By hand instead — add ONE line to the '$guser' user's ~/.ssh/authorized_keys on the"
  sj_info "receiver (restricts the key to git only):"
  echo
  printf '    command="git-shell -c \\"$SSH_ORIGINAL_COMMAND\\"",restrict %s\n' "$(cat "$authorize_key")"
  echo
  sj_info "git-shell must be installed on the receiver; then verify here:  bin/memory-sync.sh pull"
  # The clone above could not succeed yet (that is what this key unlocks), so memory-sync fell back
  # to a local repo whose commits have nowhere to go. Record the wait: SessionStart will detect the
  # authorization and publish what accumulated, rather than leaving it stranded until someone
  # notices. This is the exact state that stranded a host for three weeks.
  sj_record_pending memory git "$remote"
  sj_info "(Recorded as pending — a future session will publish automatically once authorized.)"
fi
sj_ok "cross-machine memory ready on '$(sj_host)'"

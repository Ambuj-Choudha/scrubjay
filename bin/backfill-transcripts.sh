#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# One-shot: ship every EXISTING session transcript to the relay, then catalogue the ones no row
# has ever been written for (via bin/sj-reconcile.sh). The SessionEnd hook only records sessions
# that end after it went live; this covers the back catalogue — both halves of it, since a shipped
# transcript with no catalogue row is archived but unfindable.
# Idempotent — re-running ships only new/changed files and writes no second row for a session.
# Usage: [--host NAME]
set -uo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$APP/bin/lib.sh"; sj_load_config
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJDIR="$CLAUDE_DIR/projects"
[ "${1:-}" = "--host" ] && { CLAUDE_HOST="${2:?}"; export CLAUDE_HOST; shift 2; }
HOST="$(sj_host)"
backend="${SCRUBJAY_TRANSCRIPT_BACKEND:-git}"
rc=0                                            # a partial backfill must not exit 0

# Top-level session transcripts only (projects/<slug>/<session>.jsonl) — same set the
# hook ships; excludes nested subagent transcripts.
mapfile -t files < <(find "$PROJDIR" -mindepth 2 -maxdepth 2 -name '*.jsonl' -type f 2>/dev/null | sort)
echo "found ${#files[@]} transcripts under $PROJDIR  (host=$HOST, backend=$backend)"
[ "${#files[@]}" -gt 0 ] || exit 0

if [ "$backend" = "git" ]; then
  chats="$(sj_chats)"
  [ -n "$chats" ] && [ -d "$chats/.git" ] || { echo "no chats repo at '$chats'" >&2; exit 1; }
  copy_failed=0
  for f in "${files[@]}"; do
    slug="$(basename "$(dirname "$f")")"; sid="$(basename "$f" .jsonl)"
    dst="$chats/$HOST/$slug/$sid.jsonl"
    # A copy that didn't happen stages nothing, so the commit below would have reported "already
    # up to date" for a run that archived none of the back catalogue.
    if ! { mkdir -p "$(dirname "$dst")" && cp -f "$f" "$dst"; }; then
      copy_failed=$((copy_failed+1)); echo "backfill: could not stage $slug/$sid.jsonl" >&2
    fi
  done
  cd "$chats" || { echo "backfill: cannot cd into '$chats'" >&2; exit 1; }
  git add -A || { echo "backfill: could not stage the copies in '$chats'" >&2; exit 1; }
  if git diff --cached --quiet; then
    echo "relay already up to date — nothing to push"
  else
    added="$(git diff --cached --numstat | wc -l)"
    git commit -q -m "backfill: $added transcripts from $HOST" \
      || { echo "backfill: the commit of $added transcripts failed" >&2; exit 1; }
    if sj_timeout 180 git push -q; then echo "pushed $added transcripts to scrubjay-chats"
    else
      # Committed locally is not archived: the relay is what other machines read. Warn on stderr
      # AND keep it in the exit status so a scripted caller doesn't treat this as done.
      echo "backfill: committed $added transcripts but the push FAILED — they are not on the relay yet; retry with: git -C '$chats' push" >&2
      copy_failed=$((copy_failed+1))
    fi
  fi
  [ "$copy_failed" -eq 0 ] || rc=1
else
  # transport-agnostic fallback (e.g. rsync-wg): ship each via the configured backend. One bad
  # transcript must not abort the catalogue, but a run that shipped nothing used to print the same
  # "shipped N transcripts" line as one that shipped everything.
  shipped=0; ship_failed=0
  for f in "${files[@]}"; do
    slug="$(basename "$(dirname "$f")")"; sid="$(basename "$f" .jsonl)"
    if "$APP/bin/ship-transcript.sh" "$f" "$slug" "$sid" "$HOST"; then
      shipped=$((shipped+1))
    else
      ship_failed=$((ship_failed+1)); echo "backfill: $slug/$sid did not ship" >&2
    fi
  done
  echo "shipped $shipped/${#files[@]} transcripts via $backend"
  if [ "$ship_failed" -gt 0 ]; then
    echo "backfill: $ship_failed transcript(s) FAILED to ship — see above; re-run once the backend is reachable" >&2
    rc=1
  fi
fi

# Index pass. Shipping alone leaves the back catalogue archived but invisible: /sjbrowse, /sjtable
# and /sjrecall all read logs/<host>.log, not the archive. bin/sj-reconcile.sh already writes that
# row for a session the catalogue has never heard of — reuse it rather than growing a second writer,
# since sj_log_row's format has three readers and a fourth author would drift. Delegating also buys
# the adapter-derived fields (real cwd, model, turns), the single-writer lock, and the catalogue
# re-render, none of which this loop would get for free.
#
# NOT --all, which lifts the liveness guard along with the age window. This script is run by hand
# from inside a live session, and cataloguing that session mid-flight would freeze its row at a
# partial turn count — the write-once guard means its real SessionEnd row is never written. So lift
# the age window explicitly and leave --quiet-mins doing its job. --max is needed because the cap
# only lifts on the --all path.
#
# NOSHIP: everything above is already shipped. A failure here leaves the back catalogue archived
# but unfindable, so it warns AND lands in the exit status — the transcripts that did ship stay
# shipped either way.
SCRUBJAY_HARNESS=claude SCRUBJAY_NOSHIP=1 \
  "$APP/bin/sj-reconcile.sh" --within-days 36500 --quiet-mins 30 --max 100000 \
  || { echo "backfill: catalogue index failed — run bin/sj-reconcile.sh --all by hand" >&2; rc=1; }

exit "$rc"

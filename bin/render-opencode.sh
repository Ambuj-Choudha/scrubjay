#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# Render an opencode session export (`opencode export <sid>`) as a human-readable Markdown
# conversation — the opencode counterpart of bin/render-transcript.sh, and deliberately the SAME
# output shape: a `# <title>` line, a `_N turns_` line, then `## User` / `## Assistant` blocks with
# the tool stream folded into the assistant's turn (call input, then its output).
#
# That sameness is the point. The readable/ tree is the one layer every harness shares, so /sjrecall
# and /sjbrowse search Claude and opencode sessions side by side without knowing the difference —
# and mcp/sjmcp_server.py reads the turn count straight off the `_N turns_` line.
#
#   usage: render-opencode.sh <export.json>   > out.md
#
# The export is one JSON document: { info: {id, title, directory, …},
#                                    messages: [ { info: {role, …}, parts: [ … ] } ] }
# Parts we render: text (unless synthetic/ignored — that is opencode's injected context, not the
# conversation) and tool (name + input, then the completed output). reasoning/snapshot/step-* are
# dropped, matching the Claude renderer's treatment of thinking and meta records.
set -uo pipefail
src="${1:?usage: render-opencode.sh <export.json>}"
BIN="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # bin/render.jq: the shared Markdown shape
command -v jq >/dev/null 2>&1 || { echo "(jq unavailable — cannot render $src)"; exit 0; }
[ -f "$src" ] || { echo "(export not found: $src)"; exit 0; }
# A zero-byte export means `opencode export` FAILED — say so rather than rendering it as a session
# that simply had no turns. This renderer reads one JSON document, so it runs jq WITHOUT -s (the
# other two read .jsonl streams and slurp; -s here would nest the document and break .messages).
# The cost is that an empty file gives jq zero values to iterate, the program never runs, and
# without this guard the renderer emitted nothing at all — a 0-byte .md indistinguishable from a
# genuinely empty session, and missing the `_N turns_` line mcp/sjmcp_server.py reads.
[ -s "$src" ] || { echo "(export empty — opencode export produced nothing: $src)"; exit 0; }

jq -r -L "$BIN" '
  include "render";   # hdr/2 fence/2 document/2 — shared with the Claude and codex renderers

  # a tool part: name + input (a shell command verbatim, anything else as JSON), then its output
  def render_tool(p):
    ((p.state.input // {}) as $in
     | "**→ " + (p.tool // "tool") + "**\n\n"
       + (if ($in.command? // null) != null then fence("bash"; $in.command)
          else fence("json"; ($in | tojson)) end)
       + (if (p.state.status? == "completed") and ((p.state.output // "") != "")
          then "\n\n**⎿ output:**\n\n" + fence("text"; p.state.output)
          elif (p.state.status? == "error")
          then "\n\n**⎿ error:**\n\n" + fence("text"; (p.state.error // "failed"))
          else "" end));

  [ .messages[]?
    | (.info.role // "assistant") as $role
    | ( [ .parts[]?
          | if .type == "text" and (.synthetic | not) and (.ignored | not)
              then (.text // "")
            elif .type == "tool" then render_tool(.)
            else empty end ] | join("\n\n") ) as $t
    | select(($t | gsub("\\s"; "")) != "")
    | {role: $role, text: $t}
  ] as $turns
  # opencode records a title of its own, so an export with no user turn is still nameable.
  | document($turns; (.info.title // "(no prompt)"))
' "$src" | tr -d '\000'
# One NUL byte from captured output would make rg/grep treat this rendering as binary and skip it
# in a recursive search, dropping the session out of /sjrecall. See render-transcript.sh and #66.

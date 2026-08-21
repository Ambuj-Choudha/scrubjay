# SPDX-License-Identifier: FSL-1.1-ALv2
# Copyright (c) 2026 Hendrik Baacke. See LICENSE.

# The Markdown shape every renderer emits, in one place. bin/render-transcript.sh (Claude),
# bin/render-opencode.sh and bin/render-codex.sh each know a different wire schema, but they all
# produce the SAME document: a `# <title>` line, a `_N turns_` line, then `## User` / `## Assistant`
# blocks with the tool stream folded into the assistant's turn. That sameness is load-bearing —
# /sjrecall and /sjbrowse search Claude, opencode and codex sessions side by side, and
# mcp/sjmcp_server.py reads the turn count straight off the `_N turns_` line — and it had been
# maintained by copying: three identical `hdr`/`fence` definitions and three copies of the same
# merge-and-assemble tail, where a fix to one (a heading level, the 80-char title cut, whether the
# count is pre- or post-merge) silently left the other two rendering a different document.
#
# What stays in each renderer is the part that is genuinely different: turning ITS schema into a
# flat list of {role, text} records. That list is this module's only input.
#
# Used as a jq module: jq -L <dir-of-this-file> 'include "render"; …'

# The heading for a role. Anything that is not the user is the assistant — the folded tool stream
# arrives as role "assistant", and an unknown role reads better as a reply than as a crash.
def hdr($r): if $r == "user" then "## User" else "## Assistant" end;

# A fenced block. Trailing newlines are trimmed so the closing fence sits tight against the body:
# captured command output almost always ends in one, and a blank line before ``` renders as a stray
# empty line inside the code block.
def fence($lang; $body): "```" + $lang + "\n" + ($body | rtrimstr("\n")) + "\n```";

# Consecutive same-role records merged into one block each, in order.
#
# One assistant turn is a "text → command → output → …" run arriving as several records, and each
# had to become part of ONE `## Assistant` section: a heading per record would bury the conversation
# under headings. The merged list is also what the turn count is taken from — see document/2.
def merge_blocks($turns):
  reduce $turns[] as $f ( {out: [], last: ""};
    if $f.role == .last
    then .out[-1] += "\n\n" + $f.text
    else .out += [ "\n" + hdr($f.role) + "\n\n" + $f.text ] | .last = $f.role
    end )
  | .out;

# The whole document from a flat [{role, text}] list.
#
# The title is the first user text, whitespace-collapsed and cut to 80 characters — it becomes a
# heading, and a wrapped one is useless in a search result. $fallback is what to say when there is
# no user turn to name the session with: harnesses that record a title of their own (opencode) pass
# it here, the others pass a literal.
#
# The turn count is the number of MERGED blocks, not of input records: it is reported as the size of
# the session, and a "40 turns" that counted every tool result would be an order of magnitude off.
def document($turns; $fallback):
  ( [ $turns[] | select(.role == "user") | .text ][0] // $fallback ) as $topic
  | ($topic | gsub("\\s+"; " ") | .[0:80]) as $title
  | merge_blocks($turns) as $blocks
  | "# " + $title + "\n\n_" + ($blocks | length | tostring) + " turns_\n"
    + ( $blocks | join("") );

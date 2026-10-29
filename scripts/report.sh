#!/usr/bin/env bash
# report.sh — render a Markdown size/validation report from metadata JSON.
#
# Usage: report.sh METADATA.json [METADATA.json...]
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd jq
(($#)) || die "usage: $0 METADATA.json..."

for m in "$@"; do
	jq -r '
		def mib: (. / 1048576 * 100 | round / 100 | tostring) + " MiB";
		. as $m
		| ($m.files | map(select(.compressed | not)) | map({key: .component, value: .size}) | from_entries) as $orig
		| "## \($m.artifact_base)\n",
		  "- Upstream: Tailscale \($m.upstream.tag) (`\($m.upstream.commit)`)",
		  "- Target: \($m.target.os)/\($m.target.arch)\(if $m.target.variant then " (\($m.target.variant))" else "" end), combined: \($m.target.combined)",
		  "- Toolchain: \($m.build.go_version)\(if $m.build.upx_version then ", \($m.build.upx_version)" else "" end)",
		  "- Features (\($m.build.features.mode)): \($m.build.features.add | join(", ") | if . == "" then "upstream default" else . end)\(if ($m.build.features.remove | length) > 0 then "; removed: \($m.build.features.remove | join(", "))" else "" end)",
		  (if $m.build.self_update.enabled then "- Self-update: `tailscale update` installs Tinyscale releases from \($m.build.self_update.update_url | if . == "" then "TT_UPDATE_URL (none compiled in)" else "`\(.)`" end)" else empty end),
		  "- Validation: \(if $m.validation_passed then "PASSED" else "FAILED" end)",
		  "",
		  "| File | Size | Ratio | SHA-256 | Checks |",
		  "|---|---:|---:|---|---|",
		  ($m.files[] |
		    "| `\(.file)` | \(.size) (\(.size | mib)) | \(if .compressed and $orig[.component] then ((.size * 1000 / $orig[.component] | round) / 10 | tostring) + "%" else "-" end) | `\(.sha256)` | \(.checks | map("\(.check):\(.status)") | join(" ")) |"),
		  "",
		  ([$m.files[].checks[] | select(.status != "pass")] | if length > 0 then
		    "Non-passing checks:\n" + (map("- \(.check) [\(.status)]: \(.detail)") | join("\n")) + "\n"
		  else empty end)
	' "$m"
done

#!/usr/bin/env bash
# check-published.sh — has this target/version been published successfully?
#
# Usage: check-published.sh VERSION TARGET_ID [COMMIT]
#
# Exit status: 0 published, 1 not published, 2 lookup error.
# A target counts as published only when its metadata.json (uploaded last by
# publish.sh) exists, parses, matches the version/target/commit, and records
# a passing validation. Partially uploaded targets therefore read as "not
# published" and are rebuilt.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/registry.sh
source "$(dirname "$0")/lib/registry.sh"

[[ $# -eq 2 || $# -eq 3 ]] || { echo "usage: $0 VERSION TARGET_ID [COMMIT]" >&2; exit 2; }
version="$1" target_id="$2" commit="${3:-}"
is_stable_version "$version" || { echo "invalid version: $version" >&2; exit 2; }
is_target_id "$target_id" || { echo "invalid target: $target_id" >&2; exit 2; }
registry_check_env

base="$(artifact_base "$version" "$target_id")"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

code="$(registry_get "$version" "${base}.metadata.json" "$tmp")"
case "$code" in
200) ;;
404)
	log "$base: not published"
	exit 1
	;;
*)
	warn "$base: registry lookup failed (HTTP $code)"
	exit 2
	;;
esac

if jq -e --arg b "$base" --arg v "$version" --arg t "$target_id" --arg c "$commit" '
	.artifact_base == $b and .upstream.version == $v and .target.id == $t
	and .validation_passed == true
	and ($c == "" or .upstream.commit == $c)' "$tmp" >/dev/null 2>&1; then
	log "$base: published"
	exit 0
fi
warn "$base: metadata present but does not match expected build; treating as not published"
exit 1

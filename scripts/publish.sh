#!/usr/bin/env bash
# publish.sh — upload one validated target to the GitLab Generic Package
# Registry.
#
# Usage: publish.sh DIST_TARGET_DIR
#
# DIST_TARGET_DIR is dist/<target-id>/ as produced by build-release.sh.
# Package: $TT_PACKAGE_NAME (default tailscale-tiny), version = upstream
# version. Upload order makes partial uploads safe to retry:
#   1. executables, checksum file, report, manifest
#   2. metadata.json LAST — its presence marks the target/version as
#      published (see check-published.sh)
# Files already present remotely with an identical SHA-256 are skipped, so a
# rerun after a partial upload only sends what is missing. Each upload is
# read back and verified unless TT_PUBLISH_VERIFY=false.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/registry.sh
source "$(dirname "$0")/lib/registry.sh"

[[ $# -eq 1 && -d "$1" ]] || die "usage: $0 DIST_TARGET_DIR"
dir="$(cd "$1" && pwd)"
require_cmd curl jq
registry_check_env

shopt -s nullglob
metas=("$dir"/*.metadata.json)
((${#metas[@]} == 1)) || die "expected exactly one metadata.json in $dir"
meta="${metas[0]}"
base="$(json_field "$meta" .artifact_base)"
version="$(json_field "$meta" .upstream.version)"
target_id="$(json_field "$meta" .target.id)"
[[ "$base" == "$(artifact_base "$version" "$target_id")" ]] || die "metadata artifact name mismatch"
[[ "$(json_field "$meta" .validation_passed)" == true ]] || die "$base did not pass validation; refusing to publish"
if [[ -n "${TAILSCALE_VERSION:-}" && "$TAILSCALE_VERSION" != "$version" ]]; then
	die "artifacts are for $version but pipeline expects $TAILSCALE_VERSION"
fi

sums="$dir/${base}.sha256"
[[ -f "$sums" ]] || die "missing $sums"
(cd "$dir" && sha256sum -c --quiet -- "$(basename "$sums")") || die "local checksum verification failed"

# Every executable listed in metadata must be in the checksum file and on disk.
mapfile -t exes < <(jq -r '.files[].file' "$meta")
((${#exes[@]})) || die "metadata lists no files"
for f in "${exes[@]}"; do
	[[ "$f" == "$base"* && "$f" != */* ]] || die "unexpected file name in metadata: $f"
	[[ -f "$dir/$f" ]] || die "missing $f"
	grep -q "  ${f}\$" "$sums" || die "$f missing from checksum file"
done

order=()
for f in "${exes[@]}"; do order+=("$dir/$f"); done
order+=("$sums")
[[ -f "$dir/${base}.report.md" ]] && order+=("$dir/${base}.report.md")
[[ -f "$dir/${base}.manifest" ]] && order+=("$dir/${base}.manifest")
order+=("$meta") # completion marker: always last

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

remote_matches() { # FILE: true if the registry already has identical content
	local f="$1" code
	code="$(registry_get "$version" "$(basename "$f")" "$tmp/remote")"
	case "$code" in
	200) [[ "$(sha256_of "$tmp/remote")" == "$(sha256_of "$f")" ]] ;;
	404) return 1 ;;
	*) die "registry lookup for $(basename "$f") failed (HTTP $code)" ;;
	esac
}

log "publishing $base to package ${TT_PACKAGE_NAME}/${version}"
for f in "${order[@]}"; do
	name="$(basename "$f")"
	if remote_matches "$f"; then
		log "already present with matching SHA-256: $name"
		continue
	fi
	code="$(registry_put "$version" "$f")"
	case "$code" in
	200 | 201) ;;
	400 | 403 | 409)
		die "registry rejected $name (HTTP $code). If duplicates are disabled for generic packages, a different file with this name already exists; remove it or allow duplicates before retrying."
		;;
	*) die "upload of $name failed (HTTP $code)" ;;
	esac
	if [[ "${TT_PUBLISH_VERIFY:-true}" != false ]]; then
		remote_matches "$f" || die "read-back verification failed for $name"
		log "uploaded and verified: $name"
	else
		log "uploaded: $name"
	fi
done
log "published $base"

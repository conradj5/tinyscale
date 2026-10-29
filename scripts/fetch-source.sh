#!/usr/bin/env bash
# fetch-source.sh — shallow-fetch exactly one upstream release tag.
#
# Usage: fetch-source.sh VERSION COMMIT DEST
#
# Fetches refs/tags/vVERSION at depth 1 into DEST (which must not exist or be
# empty), then verifies that:
#   * the tag resolves to COMMIT (as recorded by detect-release.sh),
#   * VERSION.txt at that commit equals VERSION.
# Never fetches the development branch.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

[[ $# -eq 3 ]] || die "usage: $0 VERSION COMMIT DEST"
version="$1" commit="$2" dest="$3"

is_stable_version "$version" || die "invalid stable version: $version"
is_commit_sha "$commit" || die "invalid commit SHA: $commit"
require_cmd git

if [[ -e "$dest" ]] && [[ -n "$(ls -A -- "$dest")" ]]; then
	die "destination $dest exists and is not empty"
fi
mkdir -p -- "$dest"

tag="v${version}"
git_q() { git -C "$dest" -c advice.detachedHead=false "$@"; }

log "fetching ${tag} from ${TT_UPSTREAM_GIT_URL}"
git_q init -q
git_q remote add origin "$TT_UPSTREAM_GIT_URL"
git_q fetch --quiet --depth 1 --no-tags origin "+refs/tags/${tag}:refs/tags/${tag}"

fetched="$(git_q rev-parse --verify "refs/tags/${tag}^{commit}")"
[[ "$fetched" == "$commit" ]] ||
	die "tag ${tag} resolves to ${fetched}, expected ${commit}; refusing to build"

git_q checkout --quiet --detach "$fetched"

[[ -f "$dest/VERSION.txt" ]] || die "VERSION.txt missing from upstream source"
upstream_version="$(tr -d '[:space:]' <"$dest/VERSION.txt")"
[[ "$upstream_version" == "$version" ]] ||
	die "VERSION.txt says '${upstream_version}', expected '${version}'"

[[ -z "$(git_q status --porcelain)" ]] || die "checkout is not clean"
log "verified ${tag} at ${commit}"

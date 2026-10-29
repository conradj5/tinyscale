#!/usr/bin/env bash
# local-build.sh — run the CI build for one or more targets on a workstation
# using Docker and the same Alpine-based Go image as CI.
#
# Usage: local-build.sh [--version X.Y.Z] [--targets id,id] [--no-cache]
#
# Defaults to the newest stable release and all enabled targets. Outputs go
# to dist/<target>/; Go caches persist in .cache/. Nothing is published.
# Requires: docker, bash, git, curl, jq, python3 + PyYAML on the host.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

version="${TAILSCALE_VERSION:-}" targets="" build_flags=()
while (($#)); do
	case "$1" in
	--version) version="$2"; shift 2 ;;
	--targets) targets="$2"; shift 2 ;;
	--no-cache) build_flags+=(--no-cache); shift ;;
	-h | --help) sed -n '2,10p' "$0"; exit 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done
require_cmd docker jq git curl python3

release_env="$(TAILSCALE_VERSION="$version" "$here/detect-release.sh")"
eval "$(grep -E '^RELEASE_[A-Z_]+=[A-Za-z0-9./:_@-]+$' <<<"$release_env")"
: "${RELEASE_VERSION:?}" "${RELEASE_COMMIT:?}" "${RELEASE_GO_IMAGE:?}"

if [[ -z "$targets" ]]; then
	targets="$(platforms_py list | paste -sd, -)"
fi
[[ -n "$targets" ]] || die "no enabled targets"

image="tinyscale-builder:${RELEASE_GO_VERSION}"
log "building helper image $image from $RELEASE_GO_IMAGE"
docker build -q "${build_flags[@]}" -f "$TT_ROOT/ci/builder.Dockerfile" \
	--build-arg "GO_IMAGE=$RELEASE_GO_IMAGE" -t "$image" "$TT_ROOT" >/dev/null

mkdir -p "$TT_ROOT/work" "$TT_ROOT/dist" "$TT_ROOT/.cache/go-mod" "$TT_ROOT/.cache/go-build"
status=0
IFS=',' read -r -a ids <<<"$targets"
for id in "${ids[@]}"; do
	mkdir -p "$TT_ROOT/work/$id"
	platforms_py show "$id" >"$TT_ROOT/work/$id/target.json"
	log "=== $id ($RELEASE_VERSION) ==="
	if ! docker run --rm --network bridge \
		-u "$(id -u):$(id -g)" -e HOME=/tmp \
		-e TT_UPDATE_URL \
		-e GOMODCACHE=/work/.cache/go-mod -e GOCACHE=/work/.cache/go-build -e GOFLAGS=-modcacherw \
		-v "$TT_ROOT:/work" -w /work "$image" \
		bash scripts/build-release.sh --version "$RELEASE_VERSION" --commit "$RELEASE_COMMIT" \
		--target-json "work/$id/target.json" --work work --dist dist; then
		warn "$id failed"
		status=1
	fi
done
exit "$status"

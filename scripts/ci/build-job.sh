#!/usr/bin/env bash
# build-job.sh — CI: build, compress and validate one target (child pipeline).
#
# Inputs: TARGET_ID, TARGET_CONFIG (resolved JSON), TAILSCALE_VERSION,
# TAILSCALE_COMMIT — all set by the generated child pipeline.
set -euo pipefail

# Tools are installed by the job's preceding `install-deps.sh build` step.
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$here/../lib/common.sh"

: "${TARGET_ID:?}" "${TAILSCALE_VERSION:?}" "${TAILSCALE_COMMIT:?}"
mkdir -p work
printf '%s' "${TARGET_CONFIG:?}" | jq . >work/target.json || die "TARGET_CONFIG is not valid JSON"
[[ "$(json_field work/target.json .id)" == "$TARGET_ID" ]] || die "TARGET_CONFIG does not describe $TARGET_ID"

export GOMODCACHE="$TT_ROOT/.cache/go-mod"
export GOCACHE="$TT_ROOT/.cache/go-build"
# Writable module cache so the runner can clean and cache it.
export GOFLAGS="-modcacherw"

"$TT_ROOT/scripts/build-release.sh" --version "$TAILSCALE_VERSION" --commit "$TAILSCALE_COMMIT" \
	--target-json work/target.json --work work --dist dist

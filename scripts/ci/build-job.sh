#!/usr/bin/env bash
# build-job.sh — CI: build, compress and validate one target (child pipeline).
#
# Inputs: TT_TARGET_ID, TT_TARGET_CONFIG (resolved JSON), TT_BUILD_VERSION,
# TT_BUILD_COMMIT — all set by the generated child pipeline.
set -euo pipefail

# Tools are installed by the job's preceding `install-deps.sh build` step.
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "$here/../lib/common.sh"

: "${TT_TARGET_ID:?}" "${TT_BUILD_VERSION:?}" "${TT_BUILD_COMMIT:?}"
mkdir -p work
printf '%s' "${TT_TARGET_CONFIG:?}" | jq . >work/target.json || die "TT_TARGET_CONFIG is not valid JSON"
[[ "$(json_field work/target.json .id)" == "$TT_TARGET_ID" ]] || die "TT_TARGET_CONFIG does not describe $TT_TARGET_ID"

export GOMODCACHE="$TT_ROOT/.cache/go-mod"
export GOCACHE="$TT_ROOT/.cache/go-build"
# Writable module cache so the runner can clean and cache it.
export GOFLAGS="-modcacherw"

"$TT_ROOT/scripts/build-release.sh" --version "$TT_BUILD_VERSION" --commit "$TT_BUILD_COMMIT" \
	--target-json work/target.json --work work --dist dist

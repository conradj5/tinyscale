#!/usr/bin/env bash
# release-job.sh — CI: create/update the GitLab Release (child pipeline).
#
# Inputs: TT_BUILD_VERSION, TT_BUILD_COMMIT, TT_RELEASE_TARGETS (comma-
# separated list of all enabled targets), set by the generated pipeline.
# Tools are installed by the job's preceding `install-deps.sh publish` step.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
IFS=',' read -r -a targets <<<"${TT_RELEASE_TARGETS:?}"
"$here/../release.sh" "${TT_BUILD_VERSION:?}" "${TT_BUILD_COMMIT:?}" "${targets[@]}"

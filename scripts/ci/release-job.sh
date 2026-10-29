#!/usr/bin/env bash
# release-job.sh — CI: create/update the GitLab Release (child pipeline).
#
# Inputs: TAILSCALE_VERSION, TAILSCALE_COMMIT, RELEASE_TARGETS (comma-
# separated list of all enabled targets), set by the generated pipeline.
# Tools are installed by the job's preceding `install-deps.sh publish` step.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
IFS=',' read -r -a targets <<<"${RELEASE_TARGETS:?}"
"$here/../release.sh" "${TAILSCALE_VERSION:?}" "${TAILSCALE_COMMIT:?}" "${targets[@]}"

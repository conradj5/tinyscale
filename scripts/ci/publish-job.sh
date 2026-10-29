#!/usr/bin/env bash
# publish-job.sh — CI: publish one validated target (child pipeline).
set -euo pipefail

# Tools are installed by the job's preceding `install-deps.sh publish` step.
here="$(cd "$(dirname "$0")" && pwd)"
"$here/../publish.sh" "dist/${TT_TARGET_ID:?}"

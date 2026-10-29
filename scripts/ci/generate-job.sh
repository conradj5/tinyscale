#!/usr/bin/env bash
# generate-job.sh — CI: decide which targets need building and write the
# child pipeline.
#
# Inputs (CI variables):
#   RELEASE_VERSION, RELEASE_COMMIT, RELEASE_GO_IMAGE   from detect-release
#   TARGETS        optional comma-separated target ids (default: all enabled)
#   FORCE_REBUILD  "true" rebuilds even if already published
#   PUBLISH        "false" builds and validates without publishing
#   ALPINE_VERSION, IMAGE_PREFIX  image selection for publish/release jobs
# Outputs: child-pipeline.yml, build-plan.txt
set -euo pipefail

# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

version="${RELEASE_VERSION:?RELEASE_VERSION missing (detect-release job)}"
commit="${RELEASE_COMMIT:?RELEASE_COMMIT missing (detect-release job)}"
go_image="${RELEASE_GO_IMAGE:?RELEASE_GO_IMAGE missing (detect-release job)}"
force="${FORCE_REBUILD:-false}"
publish="${PUBLISH:-true}"
[[ "$force" == true || "$force" == false ]] || die "FORCE_REBUILD must be true or false"
[[ "$publish" == true || "$publish" == false ]] || die "PUBLISH must be true or false"

platforms_py validate
mapfile -t enabled < <(platforms_py list)

if [[ -n "${TARGETS:-}" ]]; then
	IFS=',' read -r -a requested <<<"${TARGETS// /}"
	for id in "${requested[@]}"; do
		printf '%s\n' "${enabled[@]}" | grep -Fxq -- "$id" ||
			die "TARGETS: '$id' is not an enabled target (enabled: ${enabled[*]})"
	done
else
	requested=("${enabled[@]}")
fi

build=()
: >build-plan.txt
for id in "${requested[@]}"; do
	if [[ "$force" == true ]]; then
		reason="forced rebuild"
	elif [[ "$publish" == false ]]; then
		reason="publishing disabled; build only"
	else
		rc=0
		"$TT_ROOT/scripts/check-published.sh" "$version" "$id" "$commit" || rc=$?
		case "$rc" in
		0)
			printf '%s\tskip (already published)\n' "$id" >>build-plan.txt
			continue
			;;
		1) reason="not yet published" ;;
		*)
			# Rebuilding is safe: publish.sh skips identical remote files.
			warn "could not determine publication state of $id; building it"
			reason="publication state unknown"
			;;
		esac
	fi
	printf '%s\tbuild (%s)\n' "$id" "$reason" >>build-plan.txt
	build+=("$id")
done

pub_flag=()
[[ "$publish" == true ]] || pub_flag=(--no-publish)
platforms_py pipeline --version "$version" --commit "$commit" --go-image "$go_image" \
	--helper-image "${TT_IMAGE_PREFIX}alpine:${TT_ALPINE_VERSION}" \
	--targets "$(IFS=,; echo "${build[*]}")" "${pub_flag[@]}" -o child-pipeline.yml

log "build plan for ${version}:"
cat build-plan.txt >&2

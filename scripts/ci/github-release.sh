#!/usr/bin/env bash
# Publish the validated artifacts from this workflow run as a GitHub Release.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../lib/common.sh"
source "$here/../lib/release.sh"

artifacts="${1:?artifact directory required}"
is_stable_version "${RELEASE_VERSION:-}" || die "invalid RELEASE_VERSION"
is_commit_sha "${RELEASE_COMMIT:-}" || die "invalid RELEASE_COMMIT"
is_commit_sha "${GITHUB_SHA:-}" || die "invalid GITHUB_SHA"
: "${GITHUB_REPOSITORY:?}"
tag="v$RELEASE_VERSION"
targets="$(jq -er '.[]' <<< "${RELEASE_TARGETS:?}")"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

while IFS= read -r target; do
	is_target_id "$target" || die "invalid target id: $target"
	dir="$artifacts/tinyscale-build-$target"
	base="$(artifact_base "$RELEASE_VERSION" "$target")"
	metadata="$dir/$base.metadata.json"
	jq -e --arg version "$RELEASE_VERSION" --arg commit "$RELEASE_COMMIT" --arg target "$target" '
		.validation_passed == true and .upstream.version == $version
		and .upstream.commit == $commit and .target.id == $target and (.files | length > 0)
	' "$metadata" >/dev/null || die "$target: invalid build metadata"
	"$here/../manifest.sh" "$metadata" | cmp - "$dir/$base.manifest"
	cp -- "$dir/$base.manifest" "$stage/$target.manifest"
	cp -- "$metadata" "$dir/$base.report.md" "$dir/$base.sha256" "$stage/"
	binaries="$(jq -er '.files[] | [.file, .sha256, .size] | @tsv' "$metadata")"
	while IFS=$'\t' read -r file expected_hash expected_size; do
		[[ "$file" == "$base"* && "$file" =~ ^[a-zA-Z0-9._-]+$ ]] || die "invalid artifact name: $file"
		[[ "$(sha256_of "$dir/$file")" == "$expected_hash" && "$(wc -c < "$dir/$file")" == "$expected_size" ]] ||
			die "artifact does not match build metadata: $file"
		cp -- "$dir/$file" "$stage/"
	done <<< "$binaries"
	(cd "$stage" && sha256sum --strict --check "$base.sha256")
done <<< "$targets"

endpoint="repos/$GITHUB_REPOSITORY/releases"
release="$(gh api --paginate "$endpoint?per_page=100" |
	jq -cs --arg tag "$tag" 'add | map(select(.tag_name == $tag)) | first // empty')"
if [[ -n "$release" ]]; then
	jq -e --arg sha "$GITHUB_SHA" '.draft == true and .target_commitish == $sha' <<< "$release" >/dev/null ||
		die "$tag already exists and is published or belongs to a different source commit"
fi

# An existing tag takes precedence over --target when GitHub publishes a release.
refs="$(git ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}")"
if [[ -n "$refs" ]]; then
	tag_commit_from_ls_remote "$tag" <<< "$refs" | grep -Fxq "$GITHUB_SHA" ||
		die "$tag already points to a different source commit"
fi

if [[ -z "$release" ]]; then
	gh release create "$tag" --repo "$GITHUB_REPOSITORY" --draft --target "$GITHUB_SHA" --title "Tinyscale $RELEASE_VERSION" \
		--notes "Validated Tinyscale builds for Tailscale $RELEASE_VERSION (upstream commit $RELEASE_COMMIT)."
	release="$(gh api --paginate "$endpoint?per_page=100" |
		jq -ces --arg tag "$tag" 'add | map(select(.tag_name == $tag and .draft == true)) | first')"
fi

gh release upload "$tag" --repo "$GITHUB_REPOSITORY" --clobber "$stage"/*
id="$(jq -er '.id' <<< "$release")"
uploaded="$(gh api --paginate "$endpoint/$id/assets?per_page=100" | jq -cs 'add')"
for file in "$stage"/*; do
	digest="$(sha256sum "$file")"
	jq -e --arg name "${file##*/}" --arg digest "sha256:${digest%% *}" '
		any(.[]; .name == $name and .state == "uploaded" and .digest == $digest)
	' <<< "$uploaded" >/dev/null || die "upload verification failed for ${file##*/}"
done
gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --draft=false --latest

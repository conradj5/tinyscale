#!/usr/bin/env bash
# release.sh — create or update the GitLab Release for one upstream version.
#
# Usage: release.sh VERSION COMMIT TARGET_ID...
#
# TARGET_IDs are all enabled targets. The Release is only created once every
# one of them is published for VERSION/COMMIT (see check-published.sh);
# otherwise this exits 0 and a later pipeline creates it.
#
# The Release (and its git tag vVERSION, created at $CI_COMMIT_SHA) links to
# the package files with version-independent filepaths, so
#   <project>/-/releases/permalink/latest/downloads/<target><suffix>
# always serves the newest release, e.g. .../downloads/linux_arm64.manifest
# or .../downloads/linux_arm64.upx. A version-pinned form is
#   <project>/-/releases/vVERSION/downloads/<target><suffix>
#
# GitLab treats the most recently released Release as "latest", so a Release
# is never created for a version older than the newest existing Release
# (packages for such versions are still published). An existing Release is
# updated in place: missing asset links are added and the notes refreshed.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"
# shellcheck source=lib/release.sh
source "$here/lib/release.sh"
# shellcheck source=lib/registry.sh
source "$here/lib/registry.sh"

(($# >= 3)) || die "usage: $0 VERSION COMMIT TARGET_ID..."
version="$1" commit="$2"
shift 2
targets=("$@")
is_stable_version "$version" || die "invalid version: $version"
is_commit_sha "$commit" || die "invalid commit: $commit"
for id in "${targets[@]}"; do is_target_id "$id" || die "invalid target: $id"; done
require_cmd curl jq
registry_check_env
tag="v${version}"
name="Tinyscale ${version}"
api="/projects/${CI_PROJECT_ID}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 1. Every enabled target must be completely published.
missing=()
for id in "${targets[@]}"; do
	rc=0
	"$here/check-published.sh" "$version" "$id" "$commit" 2>/dev/null || rc=$?
	case "$rc" in
	0) ;;
	1) missing+=("$id") ;;
	*) die "could not check publication state of $id" ;;
	esac
done
if ((${#missing[@]})); then
	warn "not creating Release ${tag}: not yet published: ${missing[*]}"
	exit 0
fi

# 2. Gather metadata and build the asset links.
pkg_url() { registry_file_url "$version" "$1"; }
links='[]'
reports=()
for id in "${targets[@]}"; do
	base="$(artifact_base "$version" "$id")"
	code="$(registry_get "$version" "${base}.metadata.json" "$tmp/${id}.json")"
	[[ "$code" == 200 ]] || die "cannot download metadata for $id (HTTP $code)"
	"$here/report.sh" "$tmp/${id}.json" >"$tmp/${id}.md"
	reports+=("$tmp/${id}.md")
	files=()
	mapfile -t files < <(jq -r '.files[].file' "$tmp/${id}.json")
	files+=("${base}.manifest" "${base}.sha256" "${base}.metadata.json" "${base}.report.md")
	for f in "${files[@]}"; do
		[[ "$f" == "$base"* ]] || die "unexpected file name $f"
		suffix="${f#"$base"}"
		case "$suffix" in .manifest | .sha256 | .metadata.json | .report.md) type=other ;; *) type=package ;; esac
		links="$(jq -c --arg n "$f" --arg u "$(pkg_url "$f")" --arg p "/${id}${suffix}" --arg t "$type" \
			'. + [{name: $n, url: $u, filepath: $p, link_type: $t}]' <<<"$links")"
	done
done

project_url="${CI_PROJECT_URL:-}"
{
	printf 'Tinyscale build of upstream Tailscale [%s](https://github.com/%s/releases/tag/%s) (commit `%s`).\n\n' \
		"$tag" "$TT_UPSTREAM_REPO" "$tag" "$commit"
	printf 'Files are served from the Generic Package Registry (package `%s`, version `%s`). ' "$TT_PACKAGE_NAME" "$version"
	printf 'Each target has a `.manifest` (KEY=value: version, file names, SHA-256, sizes) for device-side scripts.\n\n'
	if [[ -n "$project_url" ]]; then
		printf 'Always-latest links (follow redirects, e.g. `curl -fL`):\n\n'
		for id in "${targets[@]}"; do
			printf -- '- `%s/-/releases/permalink/latest/downloads/%s.manifest`\n' "$project_url" "$id"
		done
		printf '\n'
	fi
	cat "${reports[@]}"
} >"$tmp/notes.md"

# 3. Create or update.
code="$(registry_api GET "${api}/releases/${tag}" "$tmp/existing.json")"
if [[ "$code" == 404 ]]; then
	code="$(registry_api GET "${api}/releases?per_page=100&order_by=released_at&sort=desc" "$tmp/all.json")"
	[[ "$code" == 200 ]] || die "cannot list releases (HTTP $code)"
	newest="$(jq -r '[.[].tag_name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) | ltrimstr("v")]
		| sort_by(split(".") | map(tonumber)) | last // empty' "$tmp/all.json")"
	if [[ -n "$newest" ]] && version_lt "$version" "$newest"; then
		warn "not creating Release ${tag}: newer Release v${newest} exists and must stay latest"
		exit 0
	fi
	[[ -n "${CI_COMMIT_SHA:-}" ]] || die "CI_COMMIT_SHA is required to create tag ${tag}"
	jq -n --arg tag "$tag" --arg ref "$CI_COMMIT_SHA" --rawfile notes "$tmp/notes.md" --argjson links "$links" \
		--arg name "$name" \
		'{name: $name, tag_name: $tag, ref: $ref, description: $notes, assets: {links: $links}}' >"$tmp/create.json"
	code="$(registry_api POST "${api}/releases" "$tmp/created.json" "$tmp/create.json")"
	case "$code" in
	201)
		log "created Release ${tag} with $(jq length <<<"$links") asset links"
		exit 0
		;;
	409) log "Release ${tag} was created concurrently; updating it" ;;
	*) die "creating Release ${tag} failed (HTTP $code): $(head -c 500 "$tmp/created.json")" ;;
	esac
elif [[ "$code" != 200 ]]; then
	die "cannot look up Release ${tag} (HTTP $code)"
fi

# Rewrite the title and notes only when they differ (ignoring trailing
# whitespace, which GitLab may normalize), so routine reruns change nothing.
notes_changed=0
if [[ ! -s "$tmp/existing.json" ]] ||
	! jq -e --rawfile notes "$tmp/notes.md" --arg name "$name" \
		'.name == $name and (.description // "" | sub("\\s+$"; "")) == ($notes | sub("\\s+$"; ""))' "$tmp/existing.json" >/dev/null; then
	jq -n --rawfile notes "$tmp/notes.md" --arg name "$name" '{name: $name, description: $notes}' >"$tmp/update.json"
	code="$(registry_api PUT "${api}/releases/${tag}" "$tmp/updated.json" "$tmp/update.json")"
	[[ "$code" == 200 ]] || die "updating Release ${tag} title and notes failed (HTTP $code)"
	notes_changed=1
fi

code="$(registry_api GET "${api}/releases/${tag}/assets/links?per_page=100" "$tmp/links.json")"
[[ "$code" == 200 ]] || die "cannot list Release ${tag} links (HTTP $code)"
added=0 changed=0
while IFS= read -r link; do
	name="$(jq -r .name <<<"$link")"
	url="$(jq -r .url <<<"$link")"
	existing="$(jq -c --arg n "$name" '[.[] | select(.name == $n)][0] // empty' "$tmp/links.json")"
	printf '%s' "$link" >"$tmp/link.json"
	if [[ -z "$existing" ]]; then
		code="$(registry_api POST "${api}/releases/${tag}/assets/links" "$tmp/out.json" "$tmp/link.json")"
		[[ "$code" == 201 ]] || die "adding link $name failed (HTTP $code): $(head -c 300 "$tmp/out.json")"
		added=$((added + 1))
	elif [[ "$(jq -r .url <<<"$existing")" != "$url" ]]; then
		code="$(registry_api PUT "${api}/releases/${tag}/assets/links/$(jq -r .id <<<"$existing")" "$tmp/out.json" "$tmp/link.json")"
		[[ "$code" == 200 ]] || die "updating link $name failed (HTTP $code)"
		changed=$((changed + 1))
	fi
done < <(jq -c '.[]' <<<"$links")
if ((added + changed + notes_changed == 0)); then
	log "Release ${tag} is up to date"
else
	log "updated Release ${tag}: ${added} link(s) added, ${changed} changed, title and notes $( ((notes_changed)) && echo updated || echo unchanged)"
fi

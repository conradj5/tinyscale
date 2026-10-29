#!/usr/bin/env bash
# build-release.sh — build, compress, validate and package one target.
#
# Usage:
#   build-release.sh --version X.Y.Z --commit SHA \
#       (--target ID [--config platforms.yml] | --target-json FILE) \
#       [--source DIR] [--work DIR] [--dist DIR]
#
# Without --source, the release is shallow-fetched (and verified) into the
# work directory. Results go to DIST/<target-id>/:
#   tailscale-tiny_<ver>_<target>[.<component>][<ext>]       uncompressed
#   tailscale-tiny_<ver>_<target>[.<component>].upx[<ext>]   compressed
#   tailscale-tiny_<ver>_<target>.sha256                     SHA-256 sums
#   tailscale-tiny_<ver>_<target>.metadata.json              build metadata
#   tailscale-tiny_<ver>_<target>.report.md                  size report
#   tailscale-tiny_<ver>_<target>.manifest                   KEY=value summary
#                                                            for device scripts
# <component> is only present for targets without a combined executable.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

version="" commit="" target_id="" config="$TT_ROOT/platforms.yml" target_json=""
source_dir="" work="$TT_ROOT/work" dist="$TT_ROOT/dist"
while (($#)); do
	case "$1" in
	--version) version="$2"; shift 2 ;;
	--commit) commit="$2"; shift 2 ;;
	--target) target_id="$2"; shift 2 ;;
	--config) config="$2"; shift 2 ;;
	--target-json) target_json="$2"; shift 2 ;;
	--source) source_dir="$2"; shift 2 ;;
	--work) work="$2"; shift 2 ;;
	--dist) dist="$2"; shift 2 ;;
	-h | --help) sed -n '2,18p' "$0"; exit 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done
is_stable_version "$version" || die "invalid or missing --version"
is_commit_sha "$commit" || die "invalid or missing --commit"
require_cmd jq

mkdir -p -- "$work" "$dist"
work="$(cd "$work" && pwd)"
dist="$(cd "$dist" && pwd)"

if [[ -z "$target_json" ]]; then
	is_target_id "$target_id" || die "invalid or missing --target"
	mkdir -p -- "$work/$target_id"
	target_json="$work/$target_id/target.json"
	platforms_py --config "$config" show "$target_id" >"$target_json"
fi
[[ -f "$target_json" ]] || die "target JSON not found: $target_json"
t() { json_field "$target_json" "$1"; }
target_id="$(t .id)"
is_target_id "$target_id" || die "invalid target id in $target_json"

tw="$work/$target_id"
out="$dist/$target_id"
rm -rf -- "$tw/raw" "$tw/validation" "$out"
mkdir -p -- "$tw/raw" "$tw/validation" "$out"

# 1. Source.
if [[ -z "$source_dir" ]]; then
	source_dir="$work/src-${version}"
	if [[ -d "$source_dir/.git" ]] &&
		[[ "$(git -C "$source_dir" rev-parse HEAD 2>/dev/null)" == "$commit" ]] &&
		[[ -z "$(git -C "$source_dir" status --porcelain)" ]]; then
		log "reusing verified source in $source_dir"
	else
		rm -rf -- "$source_dir"
		"$here/fetch-source.sh" "$version" "$commit" "$source_dir"
	fi
fi

# 2. Build.
"$here/build-target.sh" --target-json "$target_json" --source "$source_dir" \
	--out "$tw/raw" --version "$version" --commit "$commit"
build_info="$tw/raw/build-info.json"

base="$(artifact_base "$version" "$target_id")"
ext="$(t .executable_suffix)"
combined="$(t .combined)"
compress="$(t .compression.enabled)"
mapfile -t comp_args < <(jq -r '.compression.args[]' "$target_json")

# 3. Name, compress and validate each component.
status=0
results=()
validate() { # validate FILE COMPONENT [--compressed]
	local f="$1" comp="$2"; shift 2
	local res flags=()
	res="$tw/validation/$(basename "$f").json"
	[[ "$combined" == true ]] && flags+=(--combined)
	if ! "$here/validate.sh" --target-json "$target_json" --version "$version" \
		--commit "$commit" --component "$comp" --build-info "$build_info" \
		"${flags[@]}" "$@" --result "$res" "$f"; then
		status=1
	fi
	[[ -f "$res" ]] && results+=("$res")
	return 0
}

for comp in $(jq -r '.components[]' "$build_info"); do
	if [[ "$combined" == true ]]; then stem="$base"; else stem="${base}.${comp}"; fi
	plain="$out/${stem}${ext}"
	cp -- "$tw/raw/${comp}${ext}" "$plain"
	chmod 0755 "$plain"
	validate "$plain" "$comp"

	if [[ "$compress" == true ]]; then
		packed="$out/${stem}.upx${ext}"
		args=()
		for a in "${comp_args[@]}"; do args+=(--arg "$a"); done
		if "$here/compress.sh" --tool "$(t .compression.tool)" "${args[@]}" "$plain" "$packed"; then
			validate "$packed" "$comp" --compressed
		else
			log "compression failed for $(basename "$plain")"
			rm -f -- "$packed"
			status=1
		fi
	fi
done

# 4. Checksums, metadata and report.
(cd "$out" && for f in "${base}"*; do
	case "$f" in *.sha256 | *.metadata.json | *.report.md | *.manifest) continue ;; esac
	printf '%s  %s\n' "$(sha256_of "$f")" "$f"
done) >"$out/${base}.sha256"

upx_version=null
if [[ "$compress" == true ]] && command -v upx >/dev/null 2>&1; then
	upx_version="$(upx --version | sed -n 1p | jq -R .)"
fi
files_json="$(if ((${#results[@]})); then jq -s . "${results[@]}"; else echo '[]'; fi)"
jq -n \
	--arg project "$TT_PROJECT" \
	--arg version "$version" \
	--arg commit "$commit" \
	--arg base "$base" \
	--arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--arg upstream "$TT_UPSTREAM_GIT_URL" \
	--argjson target "$(cat "$target_json")" \
	--argjson build "$(cat "$build_info")" \
	--argjson files "$files_json" \
	--argjson upx "$upx_version" \
	--argjson passed "$([[ $status == 0 ]] && echo true || echo false)" \
	--arg ci_project "${CI_PROJECT_PATH:-}" \
	--arg ci_commit "${CI_COMMIT_SHA:-}" \
	--arg ci_pipeline "${CI_PIPELINE_URL:-}" \
	--arg ci_job "${CI_JOB_URL:-}" \
	'{schema: 1, project: $project, artifact_base: $base,
	  upstream: {repository: $upstream, version: $version, tag: ("v" + $version), commit: $commit},
	  target: $target, build: ($build + {upx_version: $upx}),
	  validation_passed: $passed, files: $files, created: $created,
	  ci: ({project: $ci_project, commit: $ci_commit, pipeline_url: $ci_pipeline, job_url: $ci_job}
	       | with_entries(select(.value != "")))}' >"$out/${base}.metadata.json"

"$here/report.sh" "$out/${base}.metadata.json" >"$out/${base}.report.md"
cat "$out/${base}.report.md" >&2
"$here/manifest.sh" "$out/${base}.metadata.json" >"$out/${base}.manifest"

if ((status)); then
	die "target $target_id failed validation; artifacts in $out must not be published"
fi
log "target $target_id ready in $out"

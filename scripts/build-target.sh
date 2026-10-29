#!/usr/bin/env bash
# build-target.sh — cross-compile Tailscale for one resolved target.
#
# Usage: build-target.sh --target-json FILE --source DIR --out DIR \
#                        --version X.Y.Z --commit SHA
#
# FILE is a resolved target from `tools/platforms.py show ID`. The build is
# driven through upstream's build_dist.sh so version stamping matches
# upstream; feature tags come from upstream's ./cmd/featuretags.
#
# Produces in DIR:
#   tailscaled              combined CLI+daemon (combined: true), or
#   tailscaled, tailscale   separate daemon and CLI (combined: false)
#   build-info.json         tags, toolchain, and environment used
#
# Targets with self_update: true also get the overlay in overlay/ (added to
# the build with `go build -overlay`; see docs/self-update.md). Its releases
# URL comes from TT_UPDATE_URL, or <CI_PROJECT_URL>/-/releases in CI.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

target_json="" source_dir="" out_dir="" version="" commit=""
while (($#)); do
	case "$1" in
	--target-json) target_json="$2"; shift 2 ;;
	--source) source_dir="$2"; shift 2 ;;
	--out) out_dir="$2"; shift 2 ;;
	--version) version="$2"; shift 2 ;;
	--commit) commit="$2"; shift 2 ;;
	*) die "unknown argument: $1" ;;
	esac
done
[[ -f "$target_json" && -d "$source_dir" && -n "$out_dir" ]] ||
	die "usage: $0 --target-json FILE --source DIR --out DIR --version V --commit SHA"
is_stable_version "$version" || die "invalid version: $version"
is_commit_sha "$commit" || die "invalid commit: $commit"
require_cmd go jq

target_json="$(cd "$(dirname "$target_json")" && pwd)/$(basename "$target_json")"
mkdir -p -- "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
cd -- "$source_dir"

[[ -x ./build_dist.sh && -d ./cmd/featuretags ]] ||
	die "$source_dir does not look like a Tailscale source tree"
[[ "$(tr -d '[:space:]' <VERSION.txt)" == "$version" ]] ||
	die "source VERSION.txt does not match $version"

t() { json_field "$target_json" "$1"; }
# List-valued fields may legitimately be empty, so don't use jq -e for them.
tl() { jq -r "$1" "$target_json"; }
target_id="$(t .id)"
combined="$(t .combined)"
mode="$(t .features.mode)"
add="$(tl '.features.add | join(",")')"
remove="$(tl '.features.remove | join(",")')"

# Upstream go.mod declares the minimum toolchain; never auto-download a
# different one.
export GOTOOLCHAIN=local
export GOFLAGS="${GOFLAGS:-} -mod=readonly"
go_version="$(go env GOVERSION)"
log "toolchain ${go_version}, target ${target_id}"

# Host-side helper invocations must not inherit target GOOS/GOARCH.
host_go() { env -u GOOS -u GOARCH -u GOARM -u GOAMD64 -u GO386 -u GOMIPS -u GOMIPS64 \
	-u GOARM64 -u GORISCV64 -u GOPPC64 CGO_ENABLED=0 go "$@"; }

# Validate feature names against upstream's list for this exact version.
known_features="$(host_go run ./cmd/featuretags --list | awk -F: '{gsub(/ /, "", $1); print $1}')"
for f in $(tl '.features.add[], .features.remove[]'); do
	grep -Fxq -- "$f" <<<"$known_features" ||
		die "feature '$f' is not known to Tailscale ${version} (see: go run ./cmd/featuretags --list)"
done

ft_args=()
[[ "$mode" == "minimal" ]] && ft_args+=(--min "--add=${add}")
[[ -n "$remove" ]] && ft_args+=("--remove=${remove}")
tags="$(host_go run ./cmd/featuretags "${ft_args[@]}")"

# Make the combined-binary decision explicit regardless of feature mode.
tags="$(tr ',' '\n' <<<"$tags" | grep -vx 'ts_include_cli' | grep -v '^$' || true)"
[[ "$combined" == "true" ]] && tags+=$'\nts_include_cli'
while IFS= read -r extra; do
	[[ -n "$extra" ]] && tags+=$'\n'"$extra"
done < <(tl '.extra_tags[]')
tags="$(sort -u <<<"$tags" | grep -v '^$' | paste -sd, -)"

# Version stamping: upstream's mkversion accepts these instead of walking git
# history, which a shallow clone does not have.
export TS_VERSION_LONG="${version}-t${commit:0:9}"
export TS_VERSION_GIT_HASH="$commit"
if git rev-parse --git-dir >/dev/null 2>&1; then
	TS_VERSION_GIT_DATE="$(git log -1 --format=%ct)"
	export TS_VERSION_GIT_DATE
fi

# Target environment.
while IFS='=' read -r key val; do
	export "$key=$val"
done < <(t '.go_env | to_entries[] | "\(.key)=\(.value)"')
if [[ "$(t .cgo)" == "true" ]]; then export CGO_ENABLED=1; else export CGO_ENABLED=0; fi

dist_args=()
[[ "$(t .strip)" == "true" ]] && dist_args+=(--strip)

# Self-update overlay: upstream files stay untouched; Go compiles the extra
# files as if they were in cmd/tailscale/cli.
overlay_args=()
self_update_json=null
if [[ "$(t .self_update)" == true ]]; then
	update_url="${TT_UPDATE_URL:-${CI_PROJECT_URL:+${CI_PROJECT_URL}/-/releases}}"
	if [[ -n "$update_url" ]]; then
		[[ "$update_url" =~ ^https://[A-Za-z0-9._~:/%+-]+$ ]] || die "invalid TT_UPDATE_URL: $update_url"
	else
		warn "self_update: no TT_UPDATE_URL or CI_PROJECT_URL; devices must set TT_UPDATE_URL"
	fi
	cli_dir="$PWD/cmd/tailscale/cli"
	[[ -f "$cli_dir/update.go" ]] || die "upstream layout changed: $cli_dir/update.go is missing"
	ov_src="$TT_ROOT/overlay/cmd/tailscale/cli"
	ov_gen="$(mktemp -d)"
	trap 'rm -rf "$ov_gen"' EXIT
	printf '%s\n' \
		'// Generated by Tinyscale build-target.sh. DO NOT EDIT.' '' \
		'//go:build linux' '' 'package cli' '' 'const (' \
		"	tinyUpdateTarget     = \"${target_id}\"" \
		"	tinyUpdateDefaultURL = \"${update_url}\"" \
		')' >"$ov_gen/zz_tinyupdate_config.go"
	overlay_json() { # FILE... -> overlay JSON mapping each into cmd/tailscale/cli
		jq -n --arg dir "$cli_dir" '{Replace: ($ARGS.positional | map({key: ($dir + "/" + (split("/") | last)), value: .}) | from_entries)}' --args "$@"
	}
	overlay_json "$ov_src/zz_tinyupdate.go" "$ov_gen/zz_tinyupdate_config.go" >"$ov_gen/overlay.json"
	overlay_json "$ov_src/zz_tinyupdate.go" "$ov_gen/zz_tinyupdate_config.go" "$ov_src/zz_tinyupdate_test.go" >"$ov_gen/overlay-test.json"
	log "self_update: testing the updater overlay"
	host_go test -overlay "$ov_gen/overlay-test.json" -count=1 -run '^TestTinyUpdate' ./cmd/tailscale/cli >&2 ||
		die "self_update overlay tests failed"
	overlay_args=(-overlay "$ov_gen/overlay.json")
	self_update_json="$(jq -n --arg url "$update_url" --arg sha "$(sha256_of "$ov_src/zz_tinyupdate.go")" \
		'{enabled: true, update_url: $url, overlay: [{file: "overlay/cmd/tailscale/cli/zz_tinyupdate.go", sha256: $sha}]}')"
fi

suffix="$(t .executable_suffix)"
build_one() {
	local pkg="$1" name="$2"
	log "building ${pkg} -> ${name}${suffix} (tags: ${tags:-none})"
	TAGS="$tags" ./build_dist.sh "${dist_args[@]}" "${overlay_args[@]}" -o "${out_dir}/${name}${suffix}" "$pkg"
}

if [[ "$combined" == "true" ]]; then
	build_one ./cmd/tailscaled tailscaled
	components='["tailscaled"]'
else
	build_one ./cmd/tailscaled tailscaled
	build_one ./cmd/tailscale tailscale
	components='["tailscaled","tailscale"]'
fi

jq -n \
	--arg target "$target_id" \
	--arg version "$version" \
	--arg version_long "$TS_VERSION_LONG" \
	--arg commit "$commit" \
	--arg go "$go_version" \
	--arg tags "$tags" \
	--arg cgo "$CGO_ENABLED" \
	--argjson go_env "$(t .go_env)" \
	--argjson features "$(t .features)" \
	--argjson combined "$combined" \
	--argjson strip "$(t .strip)" \
	--argjson components "$components" \
	--argjson self_update "$self_update_json" \
	'{target: $target, version: $version, version_long: $version_long,
	  commit: $commit, go_version: $go, go_env: $go_env,
	  cgo_enabled: ($cgo == "1"), combined: $combined, strip: $strip,
	  features: $features,
	  build_tags: ($tags | split(",") | map(select(. != ""))),
	  components: $components, self_update: $self_update}' >"${out_dir}/build-info.json"
log "build complete: ${out_dir}"

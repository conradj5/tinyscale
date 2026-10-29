# shellcheck shell=bash
# Shared helpers for Tailscale Tiny scripts. Source this file; do not execute.

TT_PROJECT="tailscale-tiny"
TT_UPSTREAM_REPO="${TT_UPSTREAM_REPO:-tailscale/tailscale}"
TT_UPSTREAM_GIT_URL="${TT_UPSTREAM_GIT_URL:-https://github.com/${TT_UPSTREAM_REPO}.git}"
TT_GITHUB_API="${TT_GITHUB_API:-https://api.github.com}"

# Alpine release shared by every CI image (alpine:<v> helpers and
# golang:<go>-alpine<v> builds). CI passes ALPINE_VERSION from .gitlab-ci.yml;
# this default must match it (enforced by tests/test_release.sh).
# shellcheck disable=SC2034 # used by scripts that source this file
TT_ALPINE_VERSION="${ALPINE_VERSION:-3.24}"
# Optional registry prefix for all CI images, e.g. the GitLab Dependency
# Proxy: "$CI_DEPENDENCY_PROXY_DIRECT_GROUP_IMAGE_PREFIX/" (the CI default
# for projects in a group). Empty means Docker Hub.
# shellcheck disable=SC2034 # used by scripts that source this file
TT_IMAGE_PREFIX="${IMAGE_PREFIX:-}"

# Absolute path of the repository root.
TT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

log() { printf '[%s] %s\n' "${0##*/}" "$*" >&2; }
warn() { printf '[%s] WARNING: %s\n' "${0##*/}" "$*" >&2; }
die() {
	printf '[%s] ERROR: %s\n' "${0##*/}" "$*" >&2
	exit 1
}

require_cmd() {
	local cmd
	for cmd in "$@"; do
		command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
	done
}

# Run the platform config tool. -s ignores the user site directory so a stale
# user-installed PyYAML cannot shadow the system one.
# TT_PLATFORMS_CONFIG selects another config file; a later --config wins.
platforms_py() {
	python3 -s "$TT_ROOT/tools/platforms.py" \
		--config "${TT_PLATFORMS_CONFIG:-$TT_ROOT/platforms.yml}" "$@"
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

file_size() {
	wc -c <"$1" | tr -d ' '
}

# is_stable_version VERSION: true for a plain MAJOR.MINOR.PATCH with an even
# minor number. Tailscale publishes stable releases on even minor versions and
# unstable builds on odd minor versions.
is_stable_version() {
	local v="$1" minor
	[[ "$v" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || return 1
	minor="${BASH_REMATCH[2]}"
	((minor % 2 == 0))
}

is_commit_sha() {
	[[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

is_target_id() {
	[[ "$1" =~ ^[a-z0-9]+_[a-z0-9]+(_[a-z0-9_]+)?$ ]]
}

artifact_base() {
	local version="$1" target_id="$2"
	is_stable_version "$version" || die "invalid version: $version"
	is_target_id "$target_id" || die "invalid target id: $target_id"
	printf '%s_%s_%s\n' "$TT_PROJECT" "$version" "$target_id"
}

# curl wrapper with retries, timeouts, and failure on HTTP errors.
tt_curl() {
	curl --fail --silent --show-error --location \
		--proto '=https,file' --tlsv1.2 \
		--connect-timeout 20 --max-time 600 \
		--retry 4 --retry-delay 3 --retry-connrefused \
		"$@"
}

# github_api PATH: GET from the GitHub REST API, authenticating with
# GITHUB_TOKEN when it is set (avoids the anonymous rate limit).
github_api() {
	local path="$1"
	local -a auth=()
	if [[ -n "${GITHUB_TOKEN:-}" ]]; then
		auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
	fi
	tt_curl -H 'Accept: application/vnd.github+json' \
		-H 'X-GitHub-Api-Version: 2022-11-28' \
		"${auth[@]}" "${TT_GITHUB_API}${path}"
}

# json_field FILE FILTER: print a value; fail loudly if it is missing (null).
# false is a valid value, so jq -e is not used.
json_field() {
	jq -r --arg f "$2" "$2"' | if . == null then error("missing field " + $f) else . end' "$1"
}

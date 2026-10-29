#!/usr/bin/env bash
# detect-release.sh — select the upstream Tailscale stable release to build.
#
# Usage: detect-release.sh [--version X.Y.Z] [--output FILE]
#
# Without --version (or $TAILSCALE_VERSION), selects the newest stable
# release. Writes dotenv-style variables (named RELEASE_* so they never
# collide with the TAILSCALE_VERSION request variable in GitLab's variable
# precedence):
#   RELEASE_VERSION     e.g. 1.104.4
#   RELEASE_TAG         e.g. v1.104.4
#   RELEASE_COMMIT      full commit SHA the tag points to
#   RELEASE_GO_VERSION  Go version required by upstream go.mod
#   RELEASE_GO_IMAGE    official Go container image for that version
#
# Environment:
#   GITHUB_TOKEN       optional; raises the GitHub API rate limit
#   ALPINE_VERSION     Alpine release for golang:<go>-alpine<ver> (default 3.24)
#   IMAGE_PREFIX       optional registry prefix (e.g. GitLab Dependency Proxy)
#   GO_IMAGE           optional; overrides the derived build image verbatim
#   TT_RELEASES_JSON, TT_LS_REMOTE_FILE, TT_GOMOD_FILE
#                      optional local files replacing the network lookups
#                      (used by tests and offline runs)
#   TT_CHECK_IMAGE     "false" skips checking that the derived golang tag
#                      exists on Docker Hub
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/release.sh
source "$(dirname "$0")/lib/release.sh"

version="${TAILSCALE_VERSION:-}"
output="-"
while (($#)); do
	case "$1" in
	--version) version="${2:?--version needs a value}"; shift 2 ;;
	--output) output="${2:?--output needs a value}"; shift 2 ;;
	-h | --help) sed -n '2,25p' "$0"; exit 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done

require_cmd jq git awk

version="${version#v}"
if [[ -n "$version" ]]; then
	is_stable_version "$version" ||
		die "requested version '$version' is not a stable MAJOR.MINOR.PATCH release (stable releases have an even minor number)"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 1. Release metadata.
if [[ -n "${TT_RELEASES_JSON:-}" ]]; then
	cp -- "$TT_RELEASES_JSON" "$tmp/releases.json"
elif [[ -n "$version" ]]; then
	log "checking GitHub release v${version}"
	github_api "/repos/${TT_UPSTREAM_REPO}/releases/tags/v${version}" >"$tmp/release.json" ||
		die "GitHub release v${version} not found"
	jq '[.]' "$tmp/release.json" >"$tmp/releases.json"
else
	log "listing GitHub releases for ${TT_UPSTREAM_REPO}"
	github_api "/repos/${TT_UPSTREAM_REPO}/releases?per_page=100" >"$tmp/releases.json"
fi
jq -e 'type == "array"' "$tmp/releases.json" >/dev/null ||
	die "unexpected release metadata format from GitHub"

if [[ -n "$version" ]]; then
	release_is_stable "v${version}" <"$tmp/releases.json" ||
		die "v${version} is not a published stable release (draft, prerelease, or missing)"
else
	version="$(stable_release_tags <"$tmp/releases.json" | sed -n 1p)"
	version="${version#v}"
	[[ -n "$version" ]] || die "no stable release found in GitHub metadata"
fi
is_stable_version "$version" || die "selected version '$version' failed validation"
tag="v${version}"
log "selected ${tag}"

# 2. Resolve the tag to a commit directly from git.
if [[ -n "${TT_LS_REMOTE_FILE:-}" ]]; then
	cp -- "$TT_LS_REMOTE_FILE" "$tmp/ls-remote.txt"
else
	git ls-remote --tags -- "$TT_UPSTREAM_GIT_URL" "refs/tags/${tag}" "refs/tags/${tag}^{}" >"$tmp/ls-remote.txt"
fi
commit="$(tag_commit_from_ls_remote "$tag" <"$tmp/ls-remote.txt")"
is_commit_sha "$commit" || die "could not resolve ${tag} to a commit SHA"
log "${tag} -> ${commit}"

# 3. Go toolchain version required by that commit.
if [[ -n "${TT_GOMOD_FILE:-}" ]]; then
	cp -- "$TT_GOMOD_FILE" "$tmp/go.mod"
else
	tt_curl -o "$tmp/go.mod" \
		"${TT_RAW_URL:-https://raw.githubusercontent.com}/${TT_UPSTREAM_REPO}/${commit}/go.mod"
fi
go_version="$(go_version_from_mod <"$tmp/go.mod")" || die "could not read Go version from upstream go.mod"
[[ "$TT_ALPINE_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || die "invalid ALPINE_VERSION: $TT_ALPINE_VERSION"
if [[ -n "${GO_IMAGE:-}" ]]; then
	go_image="$GO_IMAGE"
else
	go_tag="${go_version}-alpine${TT_ALPINE_VERSION}"
	# Official golang images are published for the two newest Alpine
	# releases only; fail here, clearly, rather than in every build job.
	if [[ "${TT_CHECK_IMAGE:-true}" != false ]]; then
		code="$(curl -s -o /dev/null -w '%{http_code}' --retry 3 --max-time 30 \
			"https://hub.docker.com/v2/namespaces/library/repositories/golang/tags/${go_tag}")" || code=000
		case "$code" in
		200) ;;
		404) die "golang:${go_tag} does not exist on Docker Hub; raise ALPINE_VERSION in .gitlab-ci.yml and scripts/lib/common.sh" ;;
		*) warn "could not confirm golang:${go_tag} exists (HTTP $code); continuing" ;;
		esac
	fi
	go_image="${TT_IMAGE_PREFIX}golang:${go_tag}"
fi
[[ "$go_image" =~ ^[A-Za-z0-9./:_@-]+$ ]] || die "invalid GO_IMAGE: $go_image"
log "upstream requires Go ${go_version}; image ${go_image}"

result="RELEASE_VERSION=${version}
RELEASE_TAG=${tag}
RELEASE_COMMIT=${commit}
RELEASE_GO_VERSION=${go_version}
RELEASE_GO_IMAGE=${go_image}"

if [[ "$output" == "-" ]]; then
	printf '%s\n' "$result"
else
	printf '%s\n' "$result" >"$output"
fi

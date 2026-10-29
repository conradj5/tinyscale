#!/usr/bin/env bash
# Unit tests for scripts/lib/{common,release}.sh and detect-release.sh.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$ROOT/scripts/lib/common.sh"
source "$ROOT/scripts/lib/release.sh"

echo "release selection"
assert_eq "stable tags ordered newest first, unstable/pre/draft/rc excluded" \
	"v1.104.4 v1.104.2 v1.102.4 v1.98.10" \
	"$(stable_release_tags <"$FIXTURES/releases.json" | paste -sd' ' -)"
assert_ok "release_is_stable accepts published stable tag" release_is_stable v1.104.2 <"$FIXTURES/releases.json"
for tag in v1.105.0 v1.106.0 v1.106.0-pre v1.102.5 v1.104.4-rc1 v9.9.9; do
	assert_fails "release_is_stable rejects $tag" release_is_stable "$tag" <"$FIXTURES/releases.json"
done

echo "version validation"
for v in 1.104.4 0.2.0 10.0.12; do assert_ok "is_stable_version $v" is_stable_version "$v"; done
for v in 1.105.0 1.104 1.104.4-pre v1.104.4 01.104.4 1.104.4.1 "" "1.104.4 "; do
	assert_fails "is_stable_version rejects '$v'" is_stable_version "$v"
done
assert_ok "is_commit_sha" is_commit_sha 27047635f237d1f3e0b08c0f487674757f30d2f7
assert_fails "is_commit_sha rejects short" is_commit_sha 27047635f
assert_eq "artifact_base" "tailscale-tiny_1.104.4_linux_arm_v7" "$(artifact_base 1.104.4 linux_arm_v7)"
assert_fails "artifact_base rejects bad version" artifact_base 1.105.0 linux_arm64
assert_fails "artifact_base rejects bad target" artifact_base 1.104.4 "linux/arm64"

echo "json_field"
printf '{"a": false, "b": "", "c": null, "d": [1]}' >"${TMPDIR:-/tmp}/tt-json.$$"
assert_eq "false is a value" false "$(json_field "${TMPDIR:-/tmp}/tt-json.$$" .a)"
assert_eq "empty string is a value" "" "$(json_field "${TMPDIR:-/tmp}/tt-json.$$" .b)"
assert_fails "null is missing" json_field "${TMPDIR:-/tmp}/tt-json.$$" .c
assert_fails "absent is missing" json_field "${TMPDIR:-/tmp}/tt-json.$$" .zzz
rm -f "${TMPDIR:-/tmp}/tt-json.$$"

echo "tag and toolchain parsing"
assert_eq "annotated tag is peeled" 27047635f237d1f3e0b08c0f487674757f30d2f7 \
	"$(tag_commit_from_ls_remote v1.104.4 <"$FIXTURES/ls-remote.txt")"
assert_eq "lightweight tag" 2222222222222222222222222222222222222222 \
	"$(tag_commit_from_ls_remote v1.104.2 <"$FIXTURES/ls-remote.txt")"
assert_eq "missing tag" "" "$(tag_commit_from_ls_remote v1.0.0 <"$FIXTURES/ls-remote.txt")"
assert_eq "go directive" 1.27.3 "$(go_version_from_mod <"$FIXTURES/go.mod")"
assert_eq "toolchain directive wins" 1.27.4 \
	"$(printf 'module x\n\ngo 1.27.0\n\ntoolchain go1.27.4\n' | go_version_from_mod)"
assert_fails "garbage go.mod" go_version_from_mod <<<"module x"

echo "detect-release.sh (offline fixtures)"
export TT_RELEASES_JSON="$FIXTURES/releases.json" TT_LS_REMOTE_FILE="$FIXTURES/ls-remote.txt" TT_GOMOD_FILE="$FIXTURES/go.mod" TT_CHECK_IMAGE=false
unset ALPINE_VERSION IMAGE_PREFIX || true
out="$(env -u TAILSCALE_VERSION -u GO_IMAGE "$ROOT/scripts/detect-release.sh" 2>/dev/null)"
assert_eq "selects newest stable" "RELEASE_VERSION=1.104.4
RELEASE_TAG=v1.104.4
RELEASE_COMMIT=27047635f237d1f3e0b08c0f487674757f30d2f7
RELEASE_GO_VERSION=1.27.3
RELEASE_GO_IMAGE=golang:1.27.3-alpine3.24" "$out"
out="$(GO_IMAGE=registry.example/go:1 "$ROOT/scripts/detect-release.sh" --version v1.104.2 2>/dev/null)"
assert_contains "explicit version" "$out" "RELEASE_COMMIT=2222222222222222222222222222222222222222"
assert_contains "GO_IMAGE override" "$out" "RELEASE_GO_IMAGE=registry.example/go:1"
assert_fails "rejects unstable (odd minor) request" "$ROOT/scripts/detect-release.sh" --version 1.105.0
assert_fails "rejects prerelease-flagged request" "$ROOT/scripts/detect-release.sh" --version 1.102.5
assert_fails "rejects suffix request" "$ROOT/scripts/detect-release.sh" --version 1.104.4-rc1
assert_fails "rejects unknown release" "$ROOT/scripts/detect-release.sh" --version 1.200.0
assert_fails "rejects unsafe GO_IMAGE" env GO_IMAGE='x;y' "$ROOT/scripts/detect-release.sh"
out="$(ALPINE_VERSION=3.23 IMAGE_PREFIX='gitlab.example.com:443/grp/dependency_proxy/containers/' "$ROOT/scripts/detect-release.sh" 2>/dev/null)"
assert_contains "IMAGE_PREFIX and ALPINE_VERSION applied" "$out" \
	"RELEASE_GO_IMAGE=gitlab.example.com:443/grp/dependency_proxy/containers/golang:1.27.3-alpine3.23"
out="$(IMAGE_PREFIX='proxy.example/' GO_IMAGE=registry.example/go:1 "$ROOT/scripts/detect-release.sh" 2>/dev/null)"
assert_contains "GO_IMAGE used verbatim" "$out" "RELEASE_GO_IMAGE=registry.example/go:1"
assert_fails "rejects bad ALPINE_VERSION" env ALPINE_VERSION=latest "$ROOT/scripts/detect-release.sh"
ci_alpine="$(python3 -s -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["variables"]["ALPINE_VERSION"])' "$ROOT/.gitlab-ci.yml")"
assert_eq ".gitlab-ci.yml ALPINE_VERSION matches script default" "$ci_alpine" "$(env -u ALPINE_VERSION bash -c "source '$ROOT/scripts/lib/common.sh'; echo \$TT_ALPINE_VERSION")"
# The Dependency Proxy default applies only when the proxy variable exists,
# so projects outside a group never get a "/alpine:..." image name.
proxy_rule="$(python3 -s -c '
import json, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print(json.dumps([r for r in d["workflow"]["rules"] if "IMAGE_PREFIX" in r.get("variables", {})]))' "$ROOT/.gitlab-ci.yml")"
assert_eq "workflow sets IMAGE_PREFIX from the Dependency Proxy" '${CI_DEPENDENCY_PROXY_DIRECT_GROUP_IMAGE_PREFIX}/' "$(jq -r '.[0].variables.IMAGE_PREFIX' <<<"$proxy_rule")"
assert_contains "proxy rule requires the proxy variable" "$(jq -r '.[0].if' <<<"$proxy_rule")" '&& $CI_DEPENDENCY_PROXY_DIRECT_GROUP_IMAGE_PREFIX'
assert_eq "global IMAGE_PREFIX default stays empty" "" "$(python3 -s -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["variables"]["IMAGE_PREFIX"])' "$ROOT/.gitlab-ci.yml")"
printf '[]' >"${TMPDIR:-/tmp}/tt-empty-releases.$$.json"
assert_fails "fails with no releases" env TT_RELEASES_JSON="${TMPDIR:-/tmp}/tt-empty-releases.$$.json" "$ROOT/scripts/detect-release.sh"
rm -f "${TMPDIR:-/tmp}/tt-empty-releases.$$.json"

finish

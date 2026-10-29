#!/usr/bin/env bash
# Tests for scripts/release.sh and scripts/manifest.sh against the mock API.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$ROOT/scripts/lib/common.sh"
source "$ROOT/scripts/lib/release.sh"

tmp="$(mktemp -d)"
pid=""
trap '[[ -n "$pid" ]] && kill "$pid" 2>/dev/null; rm -rf "$tmp"' EXIT
python3 -I "$TESTS_DIR/mock_registry.py" "$tmp/port" "$tmp/log" &
pid=$!
for _ in $(seq 50); do [[ -s "$tmp/port" ]] && break; sleep 0.1; done
host="http://127.0.0.1:$(cat "$tmp/port")"
export CI_API_V4_URL="$host/api/v4" CI_PROJECT_ID=42 CI_JOB_TOKEN=secret-token TT_ALLOW_INSECURE_HTTP=1 \
	CI_COMMIT_SHA=abcdefabcdefabcdefabcdefabcdefabcdefabcd CI_PROJECT_URL="$host/me/tailscale-tiny"
C=27047635f237d1f3e0b08c0f487674757f30d2f7

echo "version_lt"
assert_ok "1.104.4 < 1.104.10" version_lt 1.104.4 1.104.10
assert_ok "1.98.9 < 1.104.0" version_lt 1.98.9 1.104.0
assert_fails "1.104.4 !< 1.104.4" version_lt 1.104.4 1.104.4
assert_fails "1.106.0 !< 1.104.8" version_lt 1.106.0 1.104.8

# Build a fake, validated target and publish it through publish.sh so the
# registry contents match what CI produces.
publish_fake() { # VERSION TARGET
	local v="$1" id="$2" d="$tmp/dist/$1/$2" b
	b="tailscale-tiny_${v}_${id}"
	mkdir -p "$d"
	head -c 2048 /dev/urandom >"$d/$b"
	head -c 512 /dev/urandom >"$d/$b.upx"
	(cd "$d" && sha256sum "$b" "$b.upx" >"$b.sha256")
	jq -n --arg b "$b" --arg v "$v" --arg c "$C" --arg id "$id" \
		--arg s1 "$(sha256sum "$d/$b" | cut -d' ' -f1)" --arg s2 "$(sha256sum "$d/$b.upx" | cut -d' ' -f1)" \
		'{schema: 1, artifact_base: $b, upstream: {version: $v, tag: ("v" + $v), commit: $c},
		  target: {id: $id, os: "linux", arch: "arm64", variant: null, combined: true},
		  build: {go_version: "go1.27.3", upx_version: "upx 5", features: {mode: "minimal", add: ["cli"], remove: []}},
		  validation_passed: true,
		  files: [{file: $b, component: "tailscaled", compressed: false, size: 2048, sha256: $s1, checks: []},
		          {file: ($b + ".upx"), component: "tailscaled", compressed: true, size: 512, sha256: $s2, checks: []}]}' \
		>"$d/$b.metadata.json"
	"$ROOT/scripts/report.sh" "$d/$b.metadata.json" >"$d/$b.report.md"
	"$ROOT/scripts/manifest.sh" "$d/$b.metadata.json" >"$d/$b.manifest"
	"$ROOT/scripts/publish.sh" "$d" >/dev/null 2>&1
}
state() { curl -s "$host/__releases__"; }
rel() { "$ROOT/scripts/release.sh" "$@"; }

echo "manifest.sh"
publish_fake 1.104.4 linux_arm64
m="$tmp/dist/1.104.4/linux_arm64/tailscale-tiny_1.104.4_linux_arm64.manifest"
assert_eq "manifest version" VERSION=1.104.4 "$(grep '^VERSION=' "$m")"
assert_eq "manifest upx file" BIN_UPX_FILE=tailscale-tiny_1.104.4_linux_arm64.upx "$(grep '^BIN_UPX_FILE=' "$m")"
assert_eq "manifest upx sha" "BIN_UPX_SHA256=$(sha256sum "${m%.manifest}.upx" | cut -d' ' -f1)" "$(grep '^BIN_UPX_SHA256=' "$m")"
assert_eq "manifest has no spaces or quotes" 0 "$(grep -c "[ \"']" "$m" || true)"
# docs/manifest.md is the published contract: FORMAT comes first, and every
# key the generator can emit (combined and separate executables) is documented.
assert_eq "manifest starts with FORMAT=1" FORMAT=1 "$(sed -n 1p "$m")"
sep="$tmp/separate.metadata.json"
jq '.target.combined = false | .files += [.files[] | .component = "tailscale"]' "${m%.manifest}.metadata.json" >"$sep"
undocumented=""
for k in $({ cat "$m"; "$ROOT/scripts/manifest.sh" "$sep"; } | cut -d= -f1 | sort -u); do
	grep -qF "\`$k\`" "$ROOT/docs/manifest.md" || undocumented+="$k "
done
assert_eq "every manifest key is documented in docs/manifest.md" "" "$undocumented"

echo "release.sh"
assert_ok "deferred while a target is unpublished" rel 1.104.4 "$C" linux_arm64 linux_amd64
assert_eq "no release yet" '{}' "$(state | jq -c .releases)"
publish_fake 1.104.4 linux_amd64
assert_ok "creates release when all published" rel 1.104.4 "$C" linux_arm64 linux_amd64
assert_eq "tag created at pipeline commit" "$CI_COMMIT_SHA" "$(state | jq -r '.tags["v1.104.4"]')"
assert_eq "12 asset links" 12 "$(state | jq '.releases["v1.104.4"].links | length')"
assert_contains "notes include report" "$(state | jq -r '.releases["v1.104.4"].description')" "tailscale-tiny_1.104.4_linux_arm64.upx"
assert_contains "notes include latest permalink" "$(state | jq -r '.releases["v1.104.4"].description')" "permalink/latest/downloads/linux_arm64.manifest"

got="$(curl -sfL "$CI_PROJECT_URL/-/releases/permalink/latest/downloads/linux_arm64.manifest" -H 'JOB-TOKEN: secret-token')"
assert_contains "latest permalink serves manifest" "$got" "VERSION=1.104.4"
curl -sfL -o "$tmp/dl.upx" -H 'JOB-TOKEN: secret-token' "$CI_PROJECT_URL/-/releases/permalink/latest/downloads/linux_arm64.upx"
assert_eq "latest permalink serves binary matching manifest" \
	"$(grep '^BIN_UPX_SHA256=' <<<"$got" | cut -d= -f2)" "$(sha256sum "$tmp/dl.upx" | cut -d' ' -f1)"

: >"$tmp/log"
assert_ok "rerun is idempotent" rel 1.104.4 "$C" linux_arm64 linux_amd64
assert_eq "rerun adds no links" 0 "$(grep -c 'POST .*assets/links' "$tmp/log" || true)"
assert_eq "rerun writes nothing" 0 "$(grep -cE '^(POST|PUT) ' "$tmp/log" || true)"
assert_contains "rerun reports up to date" "$(rel 1.104.4 "$C" linux_arm64 linux_amd64 2>&1)" "Release v1.104.4 is up to date"

echo "release.sh: target added later"
publish_fake 1.104.4 linux_arm_v7
assert_ok "existing release gains new target" rel 1.104.4 "$C" linux_arm64 linux_amd64 linux_arm_v7
assert_eq "18 asset links" 18 "$(state | jq '.releases["v1.104.4"].links | length')"

echo "release.sh: version ordering"
publish_fake 1.104.6 linux_arm64
assert_ok "newer version released" rel 1.104.6 "$C" linux_arm64
assert_contains "latest moves to newer version" \
	"$(curl -sfL -H 'JOB-TOKEN: secret-token' "$CI_PROJECT_URL/-/releases/permalink/latest/downloads/linux_arm64.manifest")" "VERSION=1.104.6"
publish_fake 1.104.2 linux_arm64
assert_ok "older version handled" rel 1.104.2 "$C" linux_arm64
assert_eq "no release for older version" null "$(state | jq -c '.releases["v1.104.2"]')"
assert_contains "latest unchanged" \
	"$(curl -sfL -H 'JOB-TOKEN: secret-token' "$CI_PROJECT_URL/-/releases/permalink/latest/downloads/linux_arm64.manifest")" "VERSION=1.104.6"

echo "release.sh: input validation"
assert_fails "bad version" rel 1.105.0 "$C" linux_arm64
assert_fails "bad commit" rel 1.104.4 abc linux_arm64
assert_fails "no targets" rel 1.104.4 "$C"
assert_fails "no credentials" env -u CI_JOB_TOKEN "$ROOT/scripts/release.sh" 1.104.4 "$C" linux_arm64

finish

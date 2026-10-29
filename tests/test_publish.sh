#!/usr/bin/env bash
# Tests for publish.sh / check-published.sh against a mock registry.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

tmp="$(mktemp -d)"
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$tmp"; }
trap cleanup EXIT

V=1.104.4
C=27047635f237d1f3e0b08c0f487674757f30d2f7
ID=linux_arm64
BASE="tailscale-tiny_${V}_${ID}"

start_registry() { # LOG [mock options...]
	local log="$1"; shift
	rm -f "$tmp/port"
	python3 -I "$TESTS_DIR/mock_registry.py" "$tmp/port" "$log" "$@" &
	pids+=($!)
	for _ in $(seq 50); do [[ -s "$tmp/port" ]] && break; sleep 0.1; done
	CI_API_V4_URL="http://127.0.0.1:$(cat "$tmp/port")/api/v4"
	export CI_API_V4_URL
}

make_dist() { # DIR PASSED
	local d="$1/$ID"
	mkdir -p "$d"
	head -c 4096 /dev/urandom >"$d/$BASE"
	head -c 1024 /dev/urandom >"$d/$BASE.upx"
	echo "# report" >"$d/$BASE.report.md"
	(cd "$d" && sha256sum "$BASE" "$BASE.upx" >"$BASE.sha256")
	jq -n --arg b "$BASE" --arg v "$V" --arg c "$C" --arg id "$ID" --argjson ok "$2" \
		'{schema: 1, artifact_base: $b, upstream: {version: $v, commit: $c},
		  target: {id: $id}, validation_passed: $ok,
		  files: [{file: $b}, {file: ($b + ".upx")}]}' >"$d/$BASE.metadata.json"
}

export CI_PROJECT_ID=42 CI_JOB_TOKEN=secret-token TT_ALLOW_INSECURE_HTTP=1
unset GITLAB_TOKEN TT_BUILD_VERSION || true
pub() { "$ROOT/scripts/publish.sh" "$@"; }
chk() { "$ROOT/scripts/check-published.sh" "$@"; }
status_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }

echo "publish: fresh upload"
start_registry "$tmp/log1"
make_dist "$tmp/d1" true
assert_eq "not published initially" 1 "$(status_of chk "$V" "$ID" "$C")"
assert_ok "publish succeeds" pub "$tmp/d1/$ID"
puts="$(awk '$1 == "PUT" {n = split($2, a, "/"); print a[n]}' "$tmp/log1")"
assert_eq "upload order, metadata last" \
	"$BASE $BASE.upx $BASE.sha256 $BASE.report.md $BASE.metadata.json" "$(paste -sd' ' - <<<"$puts")"
assert_eq "all requests authenticated" "" "$(grep -v ' auth$' "$tmp/log1" || true)"
assert_eq "published afterwards" 0 "$(status_of chk "$V" "$ID" "$C")"
assert_eq "commit mismatch is not published" 1 "$(status_of chk "$V" "$ID" 0000000000000000000000000000000000000000)"
assert_eq "other target not published" 1 "$(status_of chk "$V" linux_amd64)"

echo "publish: idempotent rerun"
: >"$tmp/log1"
assert_ok "rerun succeeds" pub "$tmp/d1/$ID"
assert_eq "rerun uploads nothing" 0 "$(grep -c '^PUT' "$tmp/log1" || true)"

echo "publish: partial upload then retry"
start_registry "$tmp/log2" --fail-on "$BASE.sha256"
make_dist "$tmp/d2" true
assert_fails "upload fails midway" pub "$tmp/d2/$ID"
assert_eq "metadata never uploaded after failure" 0 "$(grep -c "PUT .*metadata.json" "$tmp/log2" || true)"
assert_eq "partial upload reads as not published" 1 "$(status_of chk "$V" "$ID" "$C")"
kill "${pids[-1]}"; wait "${pids[-1]}" 2>/dev/null || true

echo "publish: duplicates disallowed, resume after partial upload"
start_registry "$tmp/log3" --no-duplicates
make_dist "$tmp/d3" true
# Simulate an earlier job that uploaded only the first executable.
mkdir -p "$tmp/partial/$ID"
cp "$tmp/d3/$ID/$BASE" "$tmp/partial/$ID/"
curl -s -o /dev/null -H "JOB-TOKEN: $CI_JOB_TOKEN" --upload-file "$tmp/d3/$ID/$BASE" \
	"$CI_API_V4_URL/projects/42/packages/generic/tailscale-tiny/$V/$BASE"
assert_ok "resume skips identical file and completes" pub "$tmp/d3/$ID"
assert_eq "first file uploaded once" 1 "$(grep -c "PUT .*/$BASE 201" "$tmp/log3" || true)"
assert_eq "published after resume" 0 "$(status_of chk "$V" "$ID" "$C")"
make_dist "$tmp/d4" true # different content, same names
assert_fails "conflicting content rejected clearly" pub "$tmp/d4/$ID"

echo "publish: safety checks"
make_dist "$tmp/d5" false
assert_fails "refuses unvalidated artifacts" pub "$tmp/d5/$ID"
make_dist "$tmp/d6" true
echo tamper >>"$tmp/d6/$ID/$BASE"
assert_fails "refuses checksum mismatch" pub "$tmp/d6/$ID"
make_dist "$tmp/d7" true
assert_fails "refuses version mismatch with pipeline" env TT_BUILD_VERSION=1.104.2 "$ROOT/scripts/publish.sh" "$tmp/d7/$ID"
assert_fails "requires credentials" env -u CI_JOB_TOKEN "$ROOT/scripts/publish.sh" "$tmp/d7/$ID"
assert_fails "refuses plain http without test opt-in" env -u TT_ALLOW_INSECURE_HTTP "$ROOT/scripts/publish.sh" "$tmp/d7/$ID"

echo "registry redirects"
start_registry "$tmp/log4" --redirect
make_dist "$tmp/d8" true
assert_ok "publish with redirecting downloads" pub "$tmp/d8/$ID"
assert_eq "published via redirect" 0 "$(status_of chk "$V" "$ID" "$C")"
assert_eq "token never sent to redirect target" "" "$(grep '__redirect__' "$tmp/log4" | grep -v ' noauth$' || true)"
assert_eq "redirect target served objects" 0 "$(grep '__redirect__' "$tmp/log4" | grep -vc ' 200 ' || true)"

finish

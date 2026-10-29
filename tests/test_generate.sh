#!/usr/bin/env bash
# Tests for scripts/ci/generate-job.sh with a mock registry.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

tmp="$(mktemp -d)"
pid=""
trap '[[ -n "$pid" ]] && kill "$pid" 2>/dev/null; rm -rf "$tmp"' EXIT
python3 -I "$TESTS_DIR/mock_registry.py" "$tmp/port" "$tmp/log" &
pid=$!
for _ in $(seq 50); do [[ -s "$tmp/port" ]] && break; sleep 0.1; done

CI_API_V4_URL="http://127.0.0.1:$(cat "$tmp/port")/api/v4"
export CI_API_V4_URL CI_PROJECT_ID=42 \
	CI_JOB_TOKEN=secret-token TT_ALLOW_INSECURE_HTTP=1 \
	RELEASE_VERSION=1.104.4 RELEASE_COMMIT=27047635f237d1f3e0b08c0f487674757f30d2f7 \
	RELEASE_GO_IMAGE=golang:1.27.3-alpine3.24
unset TARGETS FORCE_REBUILD PUBLISH ALPINE_VERSION IMAGE_PREFIX || true
enabled="$(python3 -s "$ROOT/tools/platforms.py" --config "$ROOT/platforms.yml" list | paste -sd' ' -)"
gen() { (cd "$tmp" && "$ROOT/scripts/ci/generate-job.sh" >/dev/null 2>&1); }
jobs() { python3 -s -c 'import sys,yaml; print(" ".join(k for k in yaml.safe_load(open(sys.argv[1])) if ":" in k or k in ("nothing-to-build", "release")))' "$tmp/child-pipeline.yml"; }

echo "generate-job.sh"
assert_ok "generates with nothing published" gen
expected=""
for id in $enabled; do expected+="build:$id publish:$id "; done
assert_eq "builds every enabled target" "${expected}release" "$(jobs)"

# Mark the first enabled target as published.
first="${enabled%% *}"
base="tailscale-tiny_1.104.4_${first}"
jq -n --arg b "$base" --arg id "$first" '{artifact_base: $b, upstream: {version: "1.104.4", commit: "27047635f237d1f3e0b08c0f487674757f30d2f7"}, target: {id: $id}, validation_passed: true}' >"$tmp/meta.json"
curl -s -o /dev/null -H "JOB-TOKEN: secret-token" --upload-file "$tmp/meta.json" \
	"$CI_API_V4_URL/projects/42/packages/generic/tailscale-tiny/1.104.4/${base}.metadata.json"
assert_ok "generates with one published" gen
assert_contains "published target skipped in plan" "$(cat "$tmp/build-plan.txt")" "$first	skip (already published)"
case " $(jobs) " in *" build:$first "*) fail "published target not rebuilt" ;; *) pass "published target not rebuilt" ;; esac
assert_ok "force rebuild" env FORCE_REBUILD=true bash -c "cd '$tmp' && '$ROOT/scripts/ci/generate-job.sh' >/dev/null 2>&1"
case " $(jobs) " in *" build:$first "*) pass "forced target rebuilt" ;; *) fail "forced target rebuilt" ;; esac
assert_ok "publish disabled" env PUBLISH=false TARGETS="$first" bash -c "cd '$tmp' && '$ROOT/scripts/ci/generate-job.sh' >/dev/null 2>&1"
assert_eq "build-only plan" "build:$first" "$(jobs)"
assert_ok "image prefix" env IMAGE_PREFIX=proxy.example/grp/ bash -c "cd '$tmp' && '$ROOT/scripts/ci/generate-job.sh' >/dev/null 2>&1"
assert_eq "helper jobs use prefixed, aligned alpine" "proxy.example/grp/alpine:3.24" \
	"$(python3 -s -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["release"]["image"])' "$tmp/child-pipeline.yml")"
assert_fails "unknown TARGETS rejected" env TARGETS=linux_nope bash -c "cd '$tmp' && '$ROOT/scripts/ci/generate-job.sh'"
assert_fails "invalid FORCE_REBUILD rejected" env FORCE_REBUILD=yes bash -c "cd '$tmp' && '$ROOT/scripts/ci/generate-job.sh'"

# All published -> placeholder job only.
for id in $enabled; do
	b="tailscale-tiny_1.104.4_${id}"
	jq -n --arg b "$b" --arg id "$id" '{artifact_base: $b, upstream: {version: "1.104.4", commit: "27047635f237d1f3e0b08c0f487674757f30d2f7"}, target: {id: $id}, validation_passed: true}' >"$tmp/meta.json"
	curl -s -o /dev/null -H "JOB-TOKEN: secret-token" --upload-file "$tmp/meta.json" \
		"$CI_API_V4_URL/projects/42/packages/generic/tailscale-tiny/1.104.4/${b}.metadata.json"
done
assert_ok "generates with everything published" gen
assert_eq "only the release job" "release" "$(jobs)"

finish

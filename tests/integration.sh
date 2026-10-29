#!/usr/bin/env bash
# integration.sh — end-to-end simulation of the CI pipeline with Docker.
#
# Usage: tests/integration.sh [TARGET_ID,...]   (default: all enabled targets)
#
# 1. detect-release.sh against the real upstream (network)
# 2. generate the child pipeline
# 3. run every generated job (build:*, publish:*, release) in its own image,
#    as the runner would (fresh copy of the repository, root user), against
#    a local mock GitLab API
# 4. download through the Release "latest" permalink like a router would and
#    verify the binary against the manifest
# 5. confirm a second generate run skips everything
# Requires docker, network access, python3 + PyYAML, jq, curl.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

targets="${1:-}"
require() { command -v "$1" >/dev/null || { echo "integration.sh: needs $1" >&2; exit 2; }; }
for c in docker jq curl python3 git; do require "$c"; done

tmp="$(mktemp -d)"
pid=""
cleanup() {
	[[ -n "$pid" ]] && kill "$pid" 2>/dev/null
	# Files created by root inside containers.
	docker run --rm -v "$tmp:/t" alpine:3.24 rm -rf /t/project >/dev/null 2>&1 || true
	rm -rf "$tmp"
}
trap cleanup EXIT

echo "== detect release"
"$ROOT/scripts/detect-release.sh" --output "$tmp/release.env"
cat "$tmp/release.env"
set -a; source "$tmp/release.env"; set +a

echo "== mock GitLab"
python3 -I "$TESTS_DIR/mock_registry.py" "$tmp/port" "$tmp/registry.log" &
pid=$!
for _ in $(seq 50); do [[ -s "$tmp/port" ]] && break; sleep 0.1; done
host="http://127.0.0.1:$(cat "$tmp/port")"
export CI_API_V4_URL="$host/api/v4" CI_PROJECT_ID=42 CI_JOB_TOKEN=secret-token TT_ALLOW_INSECURE_HTTP=1 \
	CI_PROJECT_URL="$host/me/tailscale-tiny" CI_COMMIT_SHA=abcdefabcdefabcdefabcdefabcdefabcdefabcd
ci_env=(-e CI_API_V4_URL -e CI_PROJECT_ID -e CI_JOB_TOKEN -e TT_ALLOW_INSECURE_HTTP -e CI_PROJECT_URL -e CI_COMMIT_SHA)

generate() { (cd "$tmp/gen" && TARGETS="$targets" "$ROOT/scripts/ci/generate-job.sh"); }
echo "== generate child pipeline"
mkdir -p "$tmp/gen"
generate

job_field() { # JOB FIELD -> JSON
	python3 -s -c 'import json,sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print(json.dumps(d[sys.argv[2]][sys.argv[3]]))' \
		"$tmp/gen/child-pipeline.yml" "$1" "$2"
}
jobs_in_stage() {
	python3 -s -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print("\n".join(k for k,v in d.items() if isinstance(v,dict) and v.get("stage")==sys.argv[2]))' \
		"$tmp/gen/child-pipeline.yml" "$1"
}
run_job() { # JOB
	local job="$1" image script
	image="$(job_field "$job" image | jq -r .)"
	script="$(job_field "$job" script | jq -r 'join("\n")')"
	local -a envs=()
	while IFS= read -r kv; do envs+=(-e "$kv"); done < <(job_field "$job" variables | jq -r 'to_entries[] | "\(.key)=\(.value)"')
	echo "== $job in $image"
	docker run --rm --network host -v "$tmp/project:/builds/project" -w /builds/project \
		-e CI_PROJECT_DIR=/builds/project "${envs[@]}" "${ci_env[@]}" "$image" \
		sh -euc "$script"
}

# The runner starts from a clean checkout; copy only project files.
mkdir -p "$tmp/project"
tar -C "$ROOT" --exclude=./tailscale --exclude=./dist --exclude=./work --exclude=./.cache \
	--exclude=./.git --exclude='./work-*.log' -cf - . | tar -C "$tmp/project" -xf -

for stage in build publish release; do
	while IFS= read -r job; do
		[[ -n "$job" ]] && assert_ok "$job" run_job "$job"
	done < <(jobs_in_stage "$stage")
done

echo "== verify"
state="$(curl -s "$host/__releases__")"
assert_eq "Release created" "Tailscale Tiny ${RELEASE_VERSION}" "$(jq -r --arg t "v$RELEASE_VERSION" '.releases[$t].name' <<<"$state")"
assert_eq "tag at pipeline commit" "$CI_COMMIT_SHA" "$(jq -r --arg t "v$RELEASE_VERSION" '.tags[$t]' <<<"$state")"

# Router-style download of the first enabled target.
first="$(python3 -s "$ROOT/tools/platforms.py" --config "$ROOT/platforms.yml" list | sed -n 1p)"
latest="$CI_PROJECT_URL/-/releases/permalink/latest/downloads"
manifest="$(curl -sfL -H "JOB-TOKEN: $CI_JOB_TOKEN" "$latest/${first}.manifest")"
assert_contains "latest manifest version" "$manifest" "VERSION=${RELEASE_VERSION}"
curl -sfL -H "JOB-TOKEN: $CI_JOB_TOKEN" -o "$tmp/dl.upx" "$latest/${first}.upx"
assert_eq "downloaded binary matches manifest SHA-256" \
	"$(grep '^BIN_UPX_SHA256=' <<<"$manifest" | cut -d= -f2)" "$(sha256sum "$tmp/dl.upx" | cut -d' ' -f1)"

generate >/dev/null 2>&1
assert_eq "second run builds nothing" 0 "$(grep -c 'build (' "$tmp/gen/build-plan.txt" || true)"
echo "--- report"
cat "$tmp/project/dist/"*/*.report.md

finish

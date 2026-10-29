#!/usr/bin/env bash
# Negative-path tests for scripts/validate.sh using host executables, which
# can never match a cross-compiled Tailscale target. Positive paths are
# covered by tests/integration.sh with real builds.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
C=27047635f237d1f3e0b08c0f487674757f30d2f7
python3 -s "$ROOT/tools/platforms.py" --config "$ROOT/platforms.yml" show linux_arm64 >"$tmp/arm64.json"
host_exe="$(command -v ls)"
host_exe="$(readlink -f "$host_exe")"
v() { "$ROOT/scripts/validate.sh" --target-json "$tmp/arm64.json" --version 1.104.4 --commit "$C" "$@"; }

echo "validate.sh"
assert_fails "host binary fails arm64 validation" v --component tailscaled --combined --result "$tmp/r1.json" "$host_exe"
assert_eq "result written" true "$([[ -f "$tmp/r1.json" ]] && echo true || echo false)"
assert_eq "format check failed" fail "$(jq -r '.checks[] | select(.check == "format") | .status' "$tmp/r1.json")"
assert_eq "overall result failed" false "$(jq -r .passed "$tmp/r1.json")"
assert_eq "sha256 recorded" "$(sha256sum "$host_exe" | awk '{print $1}')" "$(jq -r .sha256 "$tmp/r1.json")"
if readelf -lW "$host_exe" 2>/dev/null | grep -q INTERP; then
	assert_eq "dynamic binary fails static check" fail "$(jq -r '.checks[] | select(.check == "static") | .status' "$tmp/r1.json")"
fi

printf 'not an executable\n' >"$tmp/text"
assert_fails "text file fails" v --component tailscaled --result "$tmp/r2.json" "$tmp/text"
jq '.validation.max_size = 1' "$tmp/arm64.json" >"$tmp/small.json"
"$ROOT/scripts/validate.sh" --target-json "$tmp/small.json" --version 1.104.4 --commit "$C" \
	--component tailscaled --result "$tmp/r3.json" "$host_exe" >/dev/null 2>&1 || true
assert_eq "size limit enforced" fail "$(jq -r '.checks[] | select(.check == "size") | .status' "$tmp/r3.json")"
assert_fails "rejects bad version" v --version 1.105.0 --component tailscaled --result "$tmp/r4.json" "$host_exe"
assert_fails "rejects bad component" v --component foo --result "$tmp/r5.json" "$host_exe"
assert_fails "missing file" v --component tailscaled --result "$tmp/r6.json" "$tmp/nope"

finish

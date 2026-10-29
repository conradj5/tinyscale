#!/usr/bin/env bash
# Tests for scripts/fetch-source.sh against a local upstream repository.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
up="$tmp/upstream"
git init -q "$up"
g() { git -C "$up" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
echo 1.104.2 >"$up/VERSION.txt"; g add VERSION.txt; g commit -qm old; g tag v1.104.2
echo 1.104.4 >"$up/VERSION.txt"; g commit -qam release; g tag -a -m "v1.104.4" v1.104.4
good="$(g rev-parse HEAD)"
echo 1.105.0 >"$up/VERSION.txt"; g commit -qam dev   # development branch moves on
echo 9.9.9 >"$up/VERSION.txt"; g commit -qam bad; g tag v1.104.6   # tag/VERSION.txt mismatch
bad_tag="$(g rev-parse HEAD)"

export TT_UPSTREAM_GIT_URL="file://$up"
fetch() { "$ROOT/scripts/fetch-source.sh" "$@"; }

echo "fetch-source.sh"
assert_ok "fetches annotated release tag" fetch 1.104.4 "$good" "$tmp/src1"
assert_eq "checked out the tagged commit" "$good" "$(git -C "$tmp/src1" rev-parse HEAD)"
assert_eq "VERSION.txt from tag, not dev branch" 1.104.4 "$(cat "$tmp/src1/VERSION.txt")"
assert_eq "shallow clone" true "$(git -C "$tmp/src1" rev-parse --is-shallow-repository)"
assert_fails "rejects commit mismatch" fetch 1.104.2 "$good" "$tmp/src2"
assert_fails "rejects VERSION.txt mismatch" fetch 1.104.6 "$bad_tag" "$tmp/src3"
assert_fails "rejects missing tag" fetch 1.104.8 "$good" "$tmp/src4"
assert_fails "rejects unstable version" fetch 1.105.0 "$good" "$tmp/src5"
assert_fails "rejects non-empty destination" fetch 1.104.4 "$good" "$tmp/src1"

finish

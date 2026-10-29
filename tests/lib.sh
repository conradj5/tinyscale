# shellcheck shell=bash
# Minimal assertion helpers for shell tests. Source from a test file.

# shellcheck disable=SC2034 # ROOT and FIXTURES are used by the test files
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
FIXTURES="$TESTS_DIR/fixtures"
_failures=0
_count=0

pass() { _count=$((_count + 1)); printf '  ok   %s\n' "$1"; }
fail() { _count=$((_count + 1)); _failures=$((_failures + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; return 0; }

assert_eq() { # NAME EXPECTED ACTUAL
	if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}
assert_ok() { # NAME CMD...
	local name="$1"; shift
	local out
	if out="$( ("$@") 2>&1)"; then pass "$name"; else fail "$name" "command failed: $* :: $(tail -n3 <<<"$out")"; fi
}
assert_fails() { # NAME CMD...
	local name="$1"; shift
	if ("$@") >/dev/null 2>&1; then fail "$name" "command unexpectedly succeeded: $*"; else pass "$name"; fi
}
assert_contains() { # NAME HAYSTACK NEEDLE
	if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "[$3] not found in [$(head -c 400 <<<"$2")]"; fi
}

finish() {
	printf '%s: %d checks, %d failed\n' "$(basename "$0")" "$_count" "$_failures"
	((_failures == 0))
}

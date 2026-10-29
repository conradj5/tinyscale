#!/usr/bin/env bash
# run.sh — run all offline tests: shellcheck, Python unit tests, shell tests.
# Needs bash, jq, git, curl, python3 + PyYAML, sha256sum, readelf, file.
# Lints with ShellCheck when it is installed. No Go, Docker or network needed.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
run() { echo "== $*"; "$@" || status=1; }

if command -v shellcheck >/dev/null 2>&1; then
	mapfile -t scripts < <(find scripts tests -name '*.sh' -type f | sort)
	run shellcheck -x -S warning "${scripts[@]}"
else
	echo "== shellcheck not installed; skipping lint"
fi
run python3 -s -m unittest discover -s tests -p 'test_*.py'
run python3 -s tools/platforms.py validate
for t in tests/test_*.sh; do
	run "$t"
done

if ((status)); then echo "SOME TESTS FAILED"; else echo "ALL TESTS PASSED"; fi
exit "$status"

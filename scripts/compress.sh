#!/usr/bin/env bash
# compress.sh — create a compressed copy of an executable.
#
# Usage: compress.sh --tool upx [--arg ARG]... INPUT OUTPUT
#
# INPUT is never modified. OUTPUT is written atomically and integrity-tested
# (`upx -t`) before this script reports success.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

tool="" args=()
while (($#)); do
	case "$1" in
	--tool) tool="$2"; shift 2 ;;
	--arg) args+=("$2"); shift 2 ;;
	--) shift; break ;;
	-*) die "unknown argument: $1" ;;
	*) break ;;
	esac
done
[[ $# -eq 2 ]] || die "usage: $0 --tool upx [--arg ARG]... INPUT OUTPUT"
input="$1" output="$2"
[[ -f "$input" ]] || die "no such file: $input"
[[ "$input" != "$output" ]] || die "refusing to compress in place"

case "$tool" in
upx)
	require_cmd upx
	tmp="${output}.tmp.$$"
	trap 'rm -f -- "$tmp"' EXIT
	rm -f -- "$tmp"
	log "$(upx --version | head -n1): ${args[*]} $(basename "$input")"
	upx -q "${args[@]}" -o "$tmp" -- "$input" >&2
	upx -q -t -- "$tmp" >&2
	mv -f -- "$tmp" "$output"
	trap - EXIT
	;;
*) die "unsupported compression tool: ${tool:-<none>}" ;;
esac

in_size="$(file_size "$input")"
out_size="$(file_size "$output")"
log "compressed $in_size -> $out_size bytes ($((out_size * 100 / in_size))%)"

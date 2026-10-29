#!/usr/bin/env bash
# validate.sh — platform-appropriate verification of one built executable.
#
# Usage: validate.sh --target-json FILE --version X.Y.Z --commit SHA \
#                    --component tailscaled|tailscale [--combined] \
#                    [--compressed] [--build-info FILE] --result OUT.json EXE
#
# Checks (each recorded as pass/fail/skip in OUT.json):
#   format      container format, class, endianness, machine, OS/ABI
#   entry       entry point lies inside an executable LOAD segment (ELF)
#   static      no PT_INTERP / DT_NEEDED (when validation.static is true)
#   buildinfo   Go build settings: GOOS/GOARCH/variant, CGO, tags, version
#               stamp, clean VCS state (uncompressed only; needs `go`)
#   size        against validation.max_size / max_compressed_size
#   upx         `upx -t` integrity test (compressed only)
#   smoke       runs `--version` (and the CLI `version`) via qemu or natively
#               and compares the reported version and commit
# Exits non-zero if any check fails.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/binfmt.sh
source "$(dirname "$0")/lib/binfmt.sh"

target_json="" version="" commit="" component="" combined=false compressed=false
build_info="" result=""
while (($#)); do
	case "$1" in
	--target-json) target_json="$2"; shift 2 ;;
	--version) version="$2"; shift 2 ;;
	--commit) commit="$2"; shift 2 ;;
	--component) component="$2"; shift 2 ;;
	--combined) combined=true; shift ;;
	--compressed) compressed=true; shift ;;
	--build-info) build_info="$2"; shift 2 ;;
	--result) result="$2"; shift 2 ;;
	--) shift; break ;;
	-*) die "unknown argument: $1" ;;
	*) break ;;
	esac
done
[[ $# -eq 1 ]] || die "expected exactly one executable argument"
exe="$1"
[[ -f "$exe" ]] || die "no such file: $exe"
[[ -f "$target_json" && -n "$result" ]] || die "--target-json and --result are required"
is_stable_version "$version" || die "invalid version: $version"
is_commit_sha "$commit" || die "invalid commit: $commit"
[[ "$component" == tailscaled || "$component" == tailscale ]] || die "invalid --component"
require_cmd jq file

t() { json_field "$target_json" "$1"; }
goos="$(t .os)"
goarch="$(t .arch)"
fmt="$(t .validation.format)"

checks='[]'
failed=0
record() { # record NAME STATUS DETAIL
	checks="$(jq -c --arg n "$1" --arg s "$2" --arg d "$3" '. + [{check: $n, status: $s, detail: $d}]' <<<"$checks")"
	case "$2" in
	pass) log "PASS  $1: $3" ;;
	skip) log "SKIP  $1: $3" ;;
	*) log "FAIL  $1: $3"; failed=1 ;;
	esac
}

# --- format ---------------------------------------------------------------
desc="$(file -b -- "$exe")"
if regex="$(file_regex "$fmt" "$goarch")" && [[ "$desc" =~ $regex ]]; then
	if [[ "$fmt" == elf ]]; then
		require_cmd readelf
		header="$(readelf -h -- "$exe" 2>/dev/null)" || header=""
		field() { awk -F: -v k="$1" '$1 ~ "^ *"k"$" {sub(/^[ \t]+/, "", $2); print $2; exit}' <<<"$header"; }
		if expect="$(elf_expect "$goarch")"; then
			IFS='|' read -r e_class e_data e_machine <<<"$expect"
			got="$(field Class)|$(field Data)|$(field Machine)|$(field 'OS/ABI')|$(field Type)"
			osabi="$(elf_osabi_expect "$goos")"
			if [[ "$(field Class)" == "$e_class" && "$(field Data)" == *"$e_data"* &&
				"$(field Machine)" == "$e_machine" && "$(field Type)" == EXEC* &&
				(-z "$osabi" || "$(field 'OS/ABI')" =~ $osabi) ]]; then
				record format pass "$got"
			else
				record format fail "expected $e_class/$e_data/$e_machine${osabi:+/$osabi}/EXEC, got $got"
			fi
		else
			record format fail "no ELF expectations defined for GOARCH=$goarch"
		fi
	else
		record format pass "$desc"
	fi
else
	record format fail "unexpected file type for $goos/$goarch ($fmt): $desc"
fi

# --- entry point and static linking (ELF) ----------------------------------
if [[ "$fmt" == elf ]]; then
	entry="$(readelf -h -- "$exe" | awk -F: '/Entry point address/ {gsub(/ /, "", $2); print $2}')"
	in_exec_load=false
	if [[ "$entry" =~ ^0x[0-9a-fA-F]+$ ]] && ((entry != 0)); then
		while read -r type _off vaddr _paddr _fsz memsz flags _rest; do
			[[ "$type" == LOAD && "$flags" == *E* ]] || continue
			if ((entry >= vaddr && entry < vaddr + memsz)); then in_exec_load=true; fi
		done < <(readelf -lW -- "$exe" | awk '$1 == "LOAD" {print $1, $2, $3, $4, $5, $6, $7 $8}')
	fi
	if $in_exec_load; then
		record entry pass "entry $entry in executable LOAD segment"
	else
		record entry fail "entry point '${entry:-none}' not inside an executable LOAD segment"
	fi

	if [[ "$(t .validation.static)" == true ]]; then
		interp="$(readelf -lW -- "$exe" | grep -c 'INTERP' || true)"
		needed="$(readelf -dW -- "$exe" 2>/dev/null | grep -c '(NEEDED)' || true)"
		if [[ "$interp" == 0 && "$needed" == 0 ]]; then
			record static pass "no program interpreter or shared library dependencies"
		else
			record static fail "dynamic: INTERP=$interp NEEDED=$needed"
		fi
	else
		record static skip "static linking not required for this target"
	fi
else
	record entry skip "entry point check implemented for ELF only; format check covers $fmt"
	if [[ "$(t .validation.static)" == true ]]; then
		record static fail "static validation requested but only implemented for ELF"
	else
		record static skip "static linking not required for this target"
	fi
fi

# --- Go build info (uncompressed only) -------------------------------------
if $compressed; then
	record buildinfo skip "not readable from compressed executable; checked on the uncompressed original"
elif ! command -v go >/dev/null 2>&1; then
	record buildinfo skip "go toolchain not available"
else
	bi="$(go version -m -- "$exe" 2>&1)" || bi=""
	setting() { awk -v k="$1" '$1 == "build" { split($2, kv, "="); if (kv[1] == k) { sub(/^[^=]*=/, "", $2); print $2; exit } }' <<<"$bi"; }
	problems=()
	[[ -n "$bi" ]] || problems+=("no Go build info")
	while IFS='=' read -r key val; do
		got="$(setting "$key")"
		# Go records GOARM as e.g. "7" or "7,softfloat".
		[[ "$got" == "$val" ]] || problems+=("$key=$got (want $val)")
	done < <(t '.go_env | to_entries[] | "\(.key)=\(.value)"')
	want_cgo=0
	[[ "$(t .cgo)" == true ]] && want_cgo=1
	[[ "$(setting CGO_ENABLED)" == "$want_cgo" ]] || problems+=("CGO_ENABLED=$(setting CGO_ENABLED) (want $want_cgo)")
	if [[ -n "$build_info" ]]; then
		want_tags="$(jq -r '.build_tags | join(",")' "$build_info")"
		[[ "$(setting -tags)" == "$want_tags" ]] || problems+=("build tags differ from build-info.json")
	fi
	# -trimpath keeps -ldflags out of the build info, so look for the stamped
	# long version string in the binary itself.
	main_mod="$(awk '$1 == "mod" && $2 == "tailscale.com" {print $3; exit}' <<<"$bi")"
	[[ "$main_mod" == "v${version}" ]] || problems+=("main module version ${main_mod:-missing} (want v${version})")
	grep -aqF -- "${version}-t${commit:0:9}" "$exe" ||
		problems+=("version stamp ${version}-t${commit:0:9} not embedded")
	if [[ -n "$(setting vcs.revision)" ]]; then
		[[ "$(setting vcs.revision)" == "$commit" ]] || problems+=("vcs.revision=$(setting vcs.revision)")
		[[ "$(setting vcs.modified)" == false ]] || problems+=("source tree was modified (vcs.modified=$(setting vcs.modified))")
	fi
	if ((${#problems[@]} == 0)); then
		record buildinfo pass "$(head -n1 <<<"$bi" | sed 's/^.*: //') $goos/$goarch, tags and version stamp match"
	else
		record buildinfo fail "$(IFS=';'; echo "${problems[*]}")"
	fi
fi

# --- size ------------------------------------------------------------------
size="$(file_size "$exe")"
if $compressed; then limit="$(t '.validation.max_compressed_size // "null"')"; else limit="$(t '.validation.max_size // "null"')"; fi
if [[ "$limit" == null ]]; then
	record size skip "$size bytes; no limit configured"
elif ((size <= limit)); then
	record size pass "$size bytes <= limit $limit"
else
	record size fail "$size bytes exceeds limit $limit"
fi

# --- compression integrity ---------------------------------------------------
if $compressed; then
	if command -v upx >/dev/null 2>&1; then
		if out="$(upx -q -t -- "$exe" 2>&1)"; then
			record upx pass "upx -t: $(tail -n1 <<<"$out" | tr -s ' ')"
		else
			record upx fail "upx -t failed: $out"
		fi
	else
		record upx fail "upx not available to test compressed executable"
	fi
fi

# --- runtime smoke test ----------------------------------------------------
smoke="$(t .validation.smoke_test)"
runner=()
case "$smoke" in
qemu)
	qemu="$(t .validation.qemu)"
	if [[ "$(host_goos)" == "$goos" && "$(host_goarch)" == "$goarch" ]] && [[ "$goarch" != arm ]]; then
		runner=() # native execution is possible and more faithful
	elif command -v "$qemu" >/dev/null 2>&1; then
		runner=("$qemu")
		# GOARM variants: let qemu emulate a CPU new enough for the variant.
		[[ "$goarch" == arm ]] && runner+=(-cpu max)
	else
		smoke=unavailable
	fi
	;;
native)
	[[ "$(host_goos)" == "$goos" && "$(host_goarch)" == "$goarch" ]] || smoke=unavailable
	;;
esac

run_version() { # run_version ARGV0_NAME ARGS...: print command output
	local name="$1"; shift
	local dir
	dir="$(mktemp -d)"
	ln -s -- "$(cd "$(dirname "$exe")" && pwd)/$(basename "$exe")" "$dir/$name"
	local rc=0
	timeout 120 "${runner[@]}" "$dir/$name" "$@" 2>&1 || rc=$?
	rm -rf -- "$dir"
	return "$rc"
}

check_version_output() { # LABEL OUTPUT
	local first commit_line
	first="$(head -n1 <<<"$2" | tr -d '\r')"
	commit_line="$(grep -m1 'tailscale commit:' <<<"$2" | awk '{print $3}')"
	if [[ "$first" == "$version" && ( -z "$commit_line" || "$commit_line" == "$commit" ) ]]; then
		return 0
	fi
	log "$1 output: $2"
	return 1
}

case "$smoke" in
none) record smoke skip "runtime smoke test disabled for $goos/$goarch (cannot execute on this runner)" ;;
unavailable) record smoke fail "smoke test requested but no way to execute $goos/$goarch here (missing $(t '.validation.qemu // "native host"'))" ;;
*)
	how="${runner[*]:-native}"
	detail=()
	ok=true
	# Daemon: `tailscaled --version`. CLI: `tailscale version`. The combined
	# binary acts as the CLI when invoked under the name "tailscale".
	probes=()
	[[ "$component" == tailscaled ]] && probes+=("tailscaled --version")
	if $combined || [[ "$component" == tailscale ]]; then probes+=("tailscale version"); fi
	for probe in "${probes[@]}"; do
		read -r -a argv <<<"$probe"
		if out="$(run_version "${argv[@]}")" && check_version_output "$probe" "$out"; then
			detail+=("'$probe' reports $version")
		else
			ok=false
			detail+=("'$probe' failed")
		fi
	done
	if $ok; then
		record smoke pass "via $how: ${detail[*]}"
	else
		record smoke fail "via $how: ${detail[*]}"
	fi
	;;
esac

# --- result ----------------------------------------------------------------
sha="$(sha256_of "$exe")"
jq -n --arg file "$(basename "$exe")" --arg sha "$sha" --argjson size "$size" \
	--argjson compressed "$compressed" --arg component "$component" \
	--argjson checks "$checks" --argjson ok "$([[ $failed == 0 ]] && echo true || echo false)" \
	'{file: $file, component: $component, compressed: $compressed, size: $size,
	  sha256: $sha, passed: $ok, checks: $checks}' >"$result"

if ((failed)); then
	log "validation FAILED for $(basename "$exe")"
	exit 1
fi
log "validation passed for $(basename "$exe")"

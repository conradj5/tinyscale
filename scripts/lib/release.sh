# shellcheck shell=bash
# Upstream release selection helpers. Requires common.sh and jq.

# stable_release_tags: read a GitHub "list releases" JSON array on stdin and
# print stable tags (newest version first). A release is stable when it is
# published (not a draft), not marked prerelease, tagged exactly
# vMAJOR.MINOR.PATCH, and has an even minor version.
stable_release_tags() {
	jq -r '
		[ .[]
		  | select((.draft | not) and (.prerelease | not))
		  | .tag_name
		  | select(test("^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))
		  | select((ltrimstr("v") | split(".")[1] | tonumber) % 2 == 0)
		]
		| unique
		| sort_by(ltrimstr("v") | split(".") | map(tonumber))
		| reverse
		| .[]
	'
}

# release_is_stable TAG: read the "list releases" JSON on stdin and succeed
# when TAG is one of its stable releases.
release_is_stable() {
	local tag="$1"
	stable_release_tags | grep -Fx -- "$tag" >/dev/null
}

# tag_commit_from_ls_remote TAG: read `git ls-remote --tags` output on stdin
# and print the commit the tag points at (peeled for annotated tags).
tag_commit_from_ls_remote() {
	local tag="$1"
	awk -v ref="refs/tags/${tag}" -v peeled="refs/tags/${tag}^{}" '
		$2 == peeled { p = $1 }
		$2 == ref    { d = $1 }
		END { if (p != "") print p; else if (d != "") print d }
	'
}

# go_version_from_mod: read go.mod on stdin and print the Go version that
# should be used: the toolchain directive if present, else the go directive.
go_version_from_mod() {
	awk '
		$1 == "go" && go == "" { go = $2 }
		$1 == "toolchain" { tc = $2; sub(/^go/, "", tc) }
		END {
			v = (tc != "") ? tc : go
			if (v ~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/) print v
			else exit 1
		}
	'
}

# version_lt A B: true when stable version A sorts before B (numeric
# MAJOR.MINOR.PATCH comparison).
version_lt() {
	local -a a b
	IFS=. read -r -a a <<<"$1"
	IFS=. read -r -a b <<<"$2"
	local i
	for i in 0 1 2; do
		((10#${a[i]} < 10#${b[i]})) && return 0
		((10#${a[i]} > 10#${b[i]})) && return 1
	done
	return 1
}

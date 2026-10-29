#!/bin/sh
# install-deps.sh — install tools for a CI job in an Alpine-based image.
#
# Usage: install-deps.sh PROFILE [QEMU_BINARY...]
#   PROFILE: build | publish | generate | test
#
# Runs under plain /bin/sh because bash is one of the things it installs.
# QEMU_BINARY names such as qemu-aarch64 add user-mode emulators for runtime
# smoke tests (build profile). No binfmt registration or privileges are
# needed because validate.sh invokes the emulator directly.
set -eu

if ! command -v apk >/dev/null 2>&1; then
	echo "install-deps.sh: only Alpine (apk) images are supported" >&2
	exit 1
fi

base="bash ca-certificates coreutils curl jq"
profile="${1:-}"
[ $# -gt 0 ] && shift
case "$profile" in
build) pkgs="$base file git binutils upx" ;;
publish) pkgs="$base" ;;
generate) pkgs="$base git python3 py3-yaml" ;;
test) pkgs="$base binutils file git python3 py3-yaml shellcheck" ;;
*) echo "usage: install-deps.sh build|publish|generate|test [qemu-...]" >&2; exit 2 ;;
esac

for q in "$@"; do
	case "$q" in
	qemu-[a-z0-9_]*) pkgs="$pkgs $q" ;;
	"" | null) ;;
	*) echo "install-deps.sh: invalid qemu binary name: $q" >&2; exit 1 ;;
	esac
done

# shellcheck disable=SC2086 # intentional word splitting of package list
apk add --no-cache $pkgs >/dev/null
echo "install-deps.sh: installed: $pkgs"

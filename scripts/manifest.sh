#!/usr/bin/env bash
# manifest.sh — render a target's KEY=value manifest from its metadata JSON.
#
# Usage: manifest.sh METADATA.json
#
# The manifest is meant for small device-side scripts (e.g. OpenWrt routers)
# that have no JSON parser. Lines are KEY=value with no quoting; values never
# contain spaces. Example for a combined Linux target:
#
#   FORMAT=1
#   VERSION=1.104.4
#   TAG=v1.104.4
#   COMMIT=<upstream commit>
#   TARGET=linux_arm64
#   SELF_UPDATE=0
#   BIN_FILE=tailscale-tiny_1.104.4_linux_arm64
#   BIN_SHA256=<hex>
#   BIN_SIZE=<bytes>
#   BIN_UPX_FILE=tailscale-tiny_1.104.4_linux_arm64.upx
#   BIN_UPX_SHA256=<hex>
#   BIN_UPX_SIZE=<bytes>
#
# Targets without a combined executable use TAILSCALED_* and TAILSCALE_*
# (plus *_UPX_*) instead of BIN_*.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd jq
[[ $# -eq 1 && -f "$1" ]] || die "usage: $0 METADATA.json"

jq -r '
	.target.combined as $combined
	| "FORMAT=1",
	  "VERSION=\(.upstream.version)",
	  "TAG=\(.upstream.tag)",
	  "COMMIT=\(.upstream.commit)",
	  "TARGET=\(.target.id)",
	  "SELF_UPDATE=\(if .build.self_update.enabled then 1 else 0 end)",
	  (.files[]
	   | ((if $combined then "BIN" else (.component | ascii_upcase) end)
	      + (if .compressed then "_UPX" else "" end)) as $k
	   | "\($k)_FILE=\(.file)", "\($k)_SHA256=\(.sha256)", "\($k)_SIZE=\(.size)")
' "$1"

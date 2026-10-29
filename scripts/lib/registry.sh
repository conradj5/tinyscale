# shellcheck shell=bash
# GitLab Generic Package Registry helpers. Requires common.sh.
#
# Environment:
#   CI_API_V4_URL, CI_PROJECT_ID   provided by GitLab CI
#   CI_JOB_TOKEN                   preferred credential (CI only)
#   GITLAB_TOKEN                   optional personal/project access token for
#                                  manual use outside CI (never commit it)
#   TT_PACKAGE_NAME                package name (default: tailscale-tiny)

TT_PACKAGE_NAME="${TT_PACKAGE_NAME:-$TT_PROJECT}"

registry_check_env() {
	[[ -n "${CI_API_V4_URL:-}" ]] || die "CI_API_V4_URL is not set"
	[[ "${CI_PROJECT_ID:-}" =~ ^[0-9]+$ ]] || die "CI_PROJECT_ID is not set or invalid"
	[[ -n "${CI_JOB_TOKEN:-}${GITLAB_TOKEN:-}" ]] || die "no registry credential (CI_JOB_TOKEN or GITLAB_TOKEN)"
	[[ "$TT_PACKAGE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid package name: $TT_PACKAGE_NAME"
}

# Write a curl config fragment carrying the auth header so the token never
# appears on a command line (visible in process listings).
registry_auth_config() {
	local cfg="$1"
	(
		umask 077
		if [[ -n "${CI_JOB_TOKEN:-}" ]]; then
			printf 'header = "JOB-TOKEN: %s"\n' "$CI_JOB_TOKEN" >"$cfg"
		else
			printf 'header = "PRIVATE-TOKEN: %s"\n' "$GITLAB_TOKEN" >"$cfg"
		fi
	)
}

# Plain HTTP is only allowed for local tests against a mock registry.
registry_proto() {
	if [[ "${TT_ALLOW_INSECURE_HTTP:-}" == 1 ]]; then echo '=https,http'; else echo '=https'; fi
}

registry_file_url() { # VERSION FILENAME
	printf '%s/projects/%s/packages/generic/%s/%s/%s' \
		"${CI_API_V4_URL%/}" "$CI_PROJECT_ID" "$TT_PACKAGE_NAME" "$1" "$2"
}

# registry_get VERSION FILENAME OUT: download a package file. Prints the HTTP
# status code (000 on transport failure). Redirects (e.g. to object storage)
# are followed manually and without credentials so the token never leaves
# the GitLab API host.
registry_get() {
	local version="$1" name="$2" out="$3" cfg res code redirect
	cfg="$(mktemp)"
	registry_auth_config "$cfg"
	res="$(curl --silent --proto "$(registry_proto)" \
		--connect-timeout 20 --max-time 900 --retry 4 --retry-delay 3 \
		--config "$cfg" -o "$out" -w '%{http_code} %{redirect_url}' \
		"$(registry_file_url "$version" "$name")" 2>/dev/null)" || res="${res:-000}"
	rm -f -- "$cfg"
	code="${res%% *}"
	redirect="${res#* }"
	[[ "$redirect" == "$res" ]] && redirect=""
	if [[ "$code" == 3* && -n "$redirect" ]]; then
		code="$(curl --silent --location --proto "$(registry_proto)" \
			--connect-timeout 20 --max-time 900 --retry 4 --retry-delay 3 \
			-o "$out" -w '%{http_code}' "$redirect" 2>/dev/null)" || code="${code:-000}"
	fi
	printf '%s\n' "${code:-000}"
}

# registry_api METHOD PATH OUT [JSON_FILE]: call the GitLab REST API at
# ${CI_API_V4_URL}PATH. Writes the response body to OUT and prints the HTTP
# status code (000 on transport failure).
registry_api() {
	local method="$1" path="$2" out="$3" body="${4:-}" cfg code
	local -a data=()
	[[ -n "$body" ]] && data=(-H 'Content-Type: application/json' --data-binary "@${body}")
	cfg="$(mktemp)"
	registry_auth_config "$cfg"
	code="$(curl --silent --show-error --proto "$(registry_proto)" \
		--connect-timeout 20 --max-time 120 --retry 4 --retry-delay 3 \
		--config "$cfg" -X "$method" "${data[@]}" -o "$out" -w '%{http_code}' \
		"${CI_API_V4_URL%/}${path}")" || code="${code:-000}"
	rm -f -- "$cfg"
	printf '%s\n' "${code:-000}"
}

# registry_put VERSION FILE: upload one file. Prints the HTTP status code.
registry_put() {
	local version="$1" file="$2" cfg code resp
	cfg="$(mktemp)"
	resp="$(mktemp)"
	registry_auth_config "$cfg"
	code="$(curl --silent --show-error --proto "$(registry_proto)" \
		--connect-timeout 20 --max-time 1800 --retry 4 --retry-delay 5 \
		--config "$cfg" --upload-file "$file" -o "$resp" -w '%{http_code}' \
		"$(registry_file_url "$version" "$(basename "$file")")")" || code="${code:-000}"
	if [[ "$code" != 2* ]]; then
		warn "upload of $(basename "$file") returned HTTP $code: $(head -c 500 "$resp")"
	fi
	rm -f -- "$cfg" "$resp"
	printf '%s\n' "${code:-000}"
}

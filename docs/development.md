# Development

## Local builds and tests

Requirements: Docker, bash, git, curl, jq, and python3 with PyYAML. Go is
not needed on the host; builds run in the same official `golang` Alpine
image as CI.

```sh
make test                                       # shellcheck + offline tests
make validate-config                            # check platforms.yml
make build TARGETS=linux_arm64                  # newest stable release
make build TARGETS=linux_arm64 VERSION=1.104.4  # a specific release
make integration                                # Docker end-to-end CI simulation (network)
```

`make build` works for disabled targets too, which is the easiest way to try
a new entry in `platforms.yml` before enabling it.

## Build output

`dist/<target>/` contains:

```
tailscale-tiny_1.104.4_linux_arm64                 uncompressed combined executable
tailscale-tiny_1.104.4_linux_arm64.upx             UPX-compressed copy
tailscale-tiny_1.104.4_linux_arm64.sha256          SHA-256 of the executables
tailscale-tiny_1.104.4_linux_arm64.metadata.json   build and validation metadata
tailscale-tiny_1.104.4_linux_arm64.report.md       size and validation report
tailscale-tiny_1.104.4_linux_arm64.manifest        KEY=value summary (docs/manifest.md)
```

Targets without a combined executable get one file per component, such as
`….freebsd_amd64.tailscaled` and `….freebsd_amd64.tailscale`. Windows
executables keep the `.exe` extension.

## How a target is built

`scripts/build-release.sh` runs these steps for one target:

1. **Fetch** (`fetch-source.sh`): shallow-fetch exactly the release tag and
   check the commit and `VERSION.txt`.
2. **Build** (`build-target.sh`): resolve the feature list into build tags
   with upstream's `cmd/featuretags`, then build through upstream's
   `build_dist.sh` with CGO off, stripped, `GOTOOLCHAIN=local` and the
   version stamped in.
3. **Compress** (`compress.sh`): optional UPX copy, integrity-tested. The
   uncompressed file is always kept.
4. **Validate** (`validate.sh`): see [validation.md](validation.md).
5. **Package**: checksums, `metadata.json`, report and manifest.

Builds are reproducible: the same version, target and toolchain produce
byte-identical files.

## Repository layout

| Path | Purpose |
|---|---|
| `platforms.yml` | Target list and per-target settings ([reference](platforms.md)) |
| `.gitlab-ci.yml` | Parent pipeline ([operations](ci.md)) |
| `tools/platforms.py` | Validates and resolves `platforms.yml`; generates the child pipeline |
| `scripts/detect-release.sh` | Selects and verifies the upstream stable release |
| `scripts/fetch-source.sh` | Shallow-fetches one tag; checks commit and `VERSION.txt` |
| `scripts/build-target.sh` | Cross-compiles one target through upstream `build_dist.sh` |
| `scripts/compress.sh` | Integrity-tested UPX copy |
| `scripts/validate.sh` | Binary checks and runtime smoke test |
| `scripts/build-release.sh` | Per-target driver: fetch → build → compress → validate → package |
| `scripts/report.sh`, `scripts/manifest.sh` | Report and manifest from `metadata.json` |
| `scripts/publish.sh`, `scripts/check-published.sh` | Package Registry upload and skip detection |
| `scripts/release.sh` | GitLab Release and tag with version-independent download paths |
| `scripts/local-build.sh` | Runs the CI build locally in Docker |
| `scripts/lib/` | Shared shell helpers |
| `overlay/` | Go files added to the upstream build for `self_update` targets ([self-update.md](self-update.md)) |
| `scripts/ci/` | Thin CI job wrappers and the Alpine dependency installer |
| `tests/` | Offline test suite (`tests/run.sh`), mock GitLab API, Docker integration test |

## Conventions

- Shell scripts are Bash with `set -euo pipefail` and pass shellcheck. The
  only exception is `scripts/ci/install-deps.sh`, which is POSIX `sh`
  because it runs before Bash is installed.
- Pipelines must not end in a reader that exits early (`head`,
  `grep -q`): under `pipefail` the writer's SIGPIPE fails the script.
- Behaviour comes from `platforms.yml`, not from target-specific code.
- Run `make test` before committing; CI runs the same suite.

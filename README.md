# Tailscale Tiny

Tailscale Tiny automatically builds small Tailscale executables from upstream
**stable** releases for the operating systems and CPU architectures you list
in [`platforms.yml`](platforms.yml). It validates them and publishes them to
the GitLab Generic Package Registry.

It is not tied to any router, vendor, distribution or deployment method, and
it never deploys anything to devices.

```
upstream stable tag ──► verified shallow fetch ──► cross-compile (CGO off, stripped,
                                                    upstream feature tags)
                     ──► optional UPX copy ──► validate both ──► checksums, metadata,
                                                                  size report
                     ──► Generic Package Registry (metadata.json uploaded last)
                     ──► GitLab Release + tag vX.Y.Z once all enabled targets are published
```

## Results (Tailscale 1.104.4, Go 1.27.3, UPX 5.2.0)

All builds below were produced and validated with `scripts/local-build.sh`
using the default feature set (see [Feature selection](#feature-selection)).

| Target | Executable | Uncompressed | UPX `--best --lzma` | Runtime smoke test |
|---|---|---:|---:|---|
| `linux_arm64` (enabled) | combined | 15.0 MiB | 4.0 MiB (26.7%) | qemu-aarch64 |
| `linux_amd64` (enabled) | combined | 16.3 MiB | 4.9 MiB (30.1%) | native |
| `linux_arm_v7` | combined | 15.5 MiB | 4.0 MiB (26.0%) | qemu-arm |
| `linux_riscv64` | combined | 14.4 MiB | n/a (UPX unsupported) | qemu-riscv64 |
| `freebsd_amd64` | tailscaled + tailscale | 13.9 + 9.8 MiB | n/a | none (format checks only) |
| `darwin_arm64` | tailscaled + tailscale | 13.2 + 9.4 MiB | n/a | none (format checks only) |

For comparison, the full-featured combined linux/arm64 build in this
workspace (`tailscale/tailscale.combined.original`) is 41.8 MB.

## Repository layout

| Path | Purpose |
|---|---|
| `platforms.yml` | Declarative target list and per-target settings ([schema](docs/platforms.md)) |
| `.gitlab-ci.yml` | Parent pipeline: test → detect release → generate → trigger child |
| `tools/platforms.py` | Validates/resolves `platforms.yml`; generates the child pipeline |
| `scripts/detect-release.sh` | Selects and verifies the upstream stable release |
| `scripts/fetch-source.sh` | Shallow-fetches exactly one tag; verifies commit and `VERSION.txt` |
| `scripts/build-target.sh` | Cross-compiles one target through upstream `build_dist.sh` |
| `scripts/compress.sh` | Creates an integrity-tested UPX copy (original is kept) |
| `scripts/validate.sh` | Format/arch, entry point, static linking, Go build info, size, UPX, runtime smoke test |
| `scripts/build-release.sh` | Per-target driver: fetch → build → compress → validate → package |
| `scripts/report.sh` | Markdown size/validation report from metadata |
| `scripts/publish.sh`, `scripts/check-published.sh` | Generic Package Registry upload and skip detection |
| `scripts/release.sh` | Creates/updates the GitLab Release and tag with stable "latest" download links |
| `scripts/manifest.sh` | Per-target `KEY=value` manifest for device-side update scripts |
| `scripts/local-build.sh` | Runs the CI build locally in Docker |
| `scripts/ci/` | Thin CI job wrappers and Alpine dependency installer |
| `tests/` | Offline test suite (`tests/run.sh`) and Docker integration test |
| `docs/` | [Platform schema](docs/platforms.md), [validation](docs/validation.md), [CI operations](docs/ci.md) |

## Quick start (local)

Requirements: Docker, bash, git, curl, jq, python3 with PyYAML.

```sh
make test                                   # offline tests + shellcheck
make build TARGETS=linux_arm64              # newest stable release
make build TARGETS=linux_arm64 VERSION=1.104.4
ls dist/linux_arm64/
```

`dist/<target>/` contains:

```
tailscale-tiny_1.104.4_linux_arm64                 uncompressed combined binary
tailscale-tiny_1.104.4_linux_arm64.upx             UPX-compressed copy
tailscale-tiny_1.104.4_linux_arm64.sha256          SHA-256 of the executables
tailscale-tiny_1.104.4_linux_arm64.metadata.json   build + validation metadata
tailscale-tiny_1.104.4_linux_arm64.report.md       size/compression report
tailscale-tiny_1.104.4_linux_arm64.manifest        KEY=value summary for device scripts
```

Targets without a combined executable get one file per component, for example
`tailscale-tiny_1.104.4_freebsd_amd64.tailscaled` and `….tailscale`. Windows
targets keep the `.exe` extension (`….upx.exe` when compressed).

### Using the combined binary

The combined executable runs as the daemon by default. It runs as the CLI
when it is invoked under the name `tailscale`:

```sh
install -m 0755 tailscale-tiny_1.104.4_linux_arm64 /usr/sbin/tailscaled
ln -sf /usr/sbin/tailscaled /usr/bin/tailscale
tailscale version
```

## GitLab CI/CD

The CI pipeline works on GitLab Free. See [docs/ci.md](docs/ci.md) for setup
(schedules, variables, registry permissions). In short:

- **Manual runs:** go to *Build › Pipelines › Run pipeline*. You can set
  `TAILSCALE_VERSION`, `TARGETS`, `FORCE_REBUILD` and `PUBLISH`.
- **Scheduled runs:** a pipeline schedule (for example daily) detects the
  newest stable release. Only target/version combinations that are not
  already published get built.
- **Per-target jobs:** jobs are generated from `platforms.yml`. Each target
  has its own `build:<id>` and `publish:<id>` jobs, so one failing target
  never marks another as done.
- **Publishing:** files go to the package `tailscale-tiny`, version `<upstream
  version>`, using `CI_JOB_TOKEN`. `metadata.json` is uploaded last and acts
  as the completion marker.

- **Releases:** after every enabled target is published, a `release` job
  creates a GitLab Release and the tag `v<version>`. These link to the
  package files.

## Downloading (routers and scripts)

Each Release has version-independent links. `permalink/latest` always serves
the newest Release, so a device can check for updates with fixed URLs and no
JSON parsing (public project, no token needed):

```sh
BASE=https://gitlab.com/<namespace>/tailscale-tiny/-/releases
curl -fsSL "$BASE/permalink/latest/downloads/linux_arm64.manifest"   # newest version info
curl -fsSL -o tailscaled.new "$BASE/permalink/latest/downloads/linux_arm64.upx"
curl -fsSL -o tailscaled.new "$BASE/v1.104.4/downloads/linux_arm64.upx"   # pinned version
```

Paths per target: `<target>` (uncompressed), `<target>.upx`,
`<target>.manifest`, `<target>.sha256`, `<target>.metadata.json`,
`<target>.report.md`. Targets with separate executables use
`<target>.tailscaled[.upx]` and `<target>.tailscale[.upx]`.

The manifest is plain `KEY=value` (no quoting, no spaces):

```
FORMAT=1
VERSION=1.104.4
TAG=v1.104.4
COMMIT=27047635f237d1f3e0b08c0f487674757f30d2f7
TARGET=linux_arm64
BIN_FILE=tailscale-tiny_1.104.4_linux_arm64
BIN_SHA256=bf7f92cab3e5c980e39aa5b5a81d05f8c340d7b74dc79f0baa6101e201ee64cd
BIN_SIZE=15728800
BIN_UPX_FILE=tailscale-tiny_1.104.4_linux_arm64.upx
BIN_UPX_SHA256=49df1932b22bdb780e3f7475c969a66081e4930a5e072c21b0cc9342595d99f3
BIN_UPX_SIZE=4207380
```

A device should read `VERSION` and compare it with `tailscale version`. To
avoid racing a newer Release published between requests, download the
binary from the pinned `$BASE/v$VERSION/downloads/...` path, and check
`BIN_UPX_SHA256` (or `BIN_SHA256`) before installing. Parse lines with
`grep`/`cut`; never `source` a downloaded file.

The GL.iNet GL-AX1800 and GL-B3000 both run `aarch64` kernels and use
`linux_arm64`.

## Feature selection

Tailscale supports omitting features at build time (`ts_omit_*` tags). Tailscale
Tiny does not hand-maintain tag lists. It calls upstream's
`./cmd/featuretags` for the exact release being built, so upstream resolves
feature dependencies. Feature names are also checked against that release's
list.

The default Linux profile (`features.mode: minimal`) keeps:

`cli` (combined binary), `osrouter`, `nattraversal` (and `udptransport`),
`portmapper`, `dns`, `useroutes`, `useexitnode`, `advertiseroutes`,
`advertiseexitnode`, `ipnbus`, `health`, `tailnetlock`, `bakedroots`,
`unixsocketidentity`, `iptables`, `sdnotify`, `resolved`, plus anything
upstream marks as a dependency (for example `c2n`, `peerapiserver`).

The default profile **omits**, among others: netstack (userspace networking,
`--tun=userspace-networking`), Tailscale SSH, Serve/Funnel, Taildrop, the web
client, Drive, App Connectors, peer relay server, log upload (logtail),
auto-update, MDM/syspolicy, and NetworkManager/D-Bus integration.

To get a feature back, add it to `features.add` for a target or OS. To build
upstream's full feature set minus specific features, use
`features.mode: full`. See [docs/platforms.md](docs/platforms.md).

## Adding a platform

Add or enable an entry in `platforms.yml`:

```yaml
  - os: linux
    arch: arm
    goarm: "7"
    enabled: true
```

Run `python3 tools/platforms.py validate`, then `make build TARGETS=linux_arm_v7`.
No pipeline changes are needed.

## Validation and limitations

See [docs/validation.md](docs/validation.md) for what each check proves and
what it does not. Key limitations:

- The runtime smoke test runs `tailscaled --version` and `tailscale version`
  (via QEMU user-mode or natively). It does not bring up a TUN device or
  connect to a tailnet.
- Non-Linux targets (FreeBSD, macOS, Windows) cannot be run on GitLab's Linux
  runners. They get format, build-info, version-stamp and size checks only.
- macOS binaries are ad-hoc signed by the Go linker but not notarized.
- UPX binaries decompress into memory at startup. They use more RAM and start
  more slowly than the uncompressed file. Prefer the uncompressed file when
  storage allows.

## Security

- Release metadata comes from the GitHub API. The tag→commit mapping is
  resolved independently through `git ls-remote` and rechecked after the
  fetch, and `VERSION.txt` must match.
- Only `refs/tags/vX.Y.Z` is fetched (depth 1). The development branch is
  never used.
- Go modules are verified against upstream `go.sum` and the Go checksum
  database (`-mod=readonly`). `GOTOOLCHAIN=local` prevents silent toolchain
  downloads.
- Publishing uses `CI_JOB_TOKEN`. The token goes in a curl config file, not on
  the command line, and is never sent to redirect targets (object storage).
- No privileged containers are used. QEMU runs in user mode without binfmt.

# Tinyscale

Tinyscale builds small Tailscale executables from upstream **stable**
releases, for whichever operating systems and CPU architectures are listed in
[`platforms.yml`](platforms.yml). A scheduled GitLab pipeline notices each
new release, cross-compiles and validates every enabled target, and publishes
the results as a GitLab Release.

The builds keep core VPN functionality (subnet routes, exit nodes, MagicDNS,
NAT traversal) and leave out features that small devices rarely need. The
linux/arm64 executable is about 15 MiB, or 4 MiB UPX-compressed, compared
with about 42 MB for the full upstream build.

The project isn't tied to any router, vendor or distribution, and it never
installs anything on devices. Devices fetch builds when they choose to.

## How it works

```
GitHub: newest stable tag ─► verified shallow fetch of that tag
  ─► per target: cross-compile ─► optional UPX copy ─► validate (format, arch,
     static linking, build info, version, size, run under QEMU)
  ─► GitLab Package Registry ─► GitLab Release v<version> + tag
```

Each target gets its own build and publish jobs, generated from
`platforms.yml`. Targets already published for a version are skipped, so a
daily run with nothing new finishes in about a minute.

## Getting a build

Download from the project's Releases page, or use the fixed "latest" URLs:

```sh
url=<project URL>/-/releases
curl -fL -O "$url/permalink/latest/downloads/linux_arm64.manifest"   # version, file names, SHA-256
curl -fL -o tailscaled "$url/v1.104.4/downloads/linux_arm64"          # pinned version
```

Each target has an uncompressed executable, a UPX copy where supported, a
checksum file and a small `KEY=value` manifest that update scripts can read
without a JSON parser. On Linux, the single executable is both the daemon and
the CLI: install it as `tailscaled` and symlink `tailscale` to it.

[docs/manifest.md](docs/manifest.md) describes the URLs, the manifest format
and the compatibility guarantees that update scripts can rely on.

Optionally, a target can be built with `self_update: true`, so that
`tailscale update` and the admin console's Update button install Tailscale
Tiny releases ([docs/self-update.md](docs/self-update.md)).

## Running the pipeline

The pipeline runs on GitLab Free, with shared or self-hosted runners.

1. Push this repository to a GitLab project.
2. Create a pipeline schedule (*Build › Pipeline schedules*), for example
   daily, on the default branch.
3. To build right away, use *Build › Pipelines › Run pipeline*. Optional
   variables: `TAILSCALE_VERSION`, `TARGETS`, `FORCE_REBUILD`, `PUBLISH`.

Publishing uses the job's own `CI_JOB_TOKEN`, so no secrets are needed.
[docs/ci.md](docs/ci.md) covers the variables, the Dependency Proxy,
Releases, and retry behaviour.

## Building locally

Requirements: Docker, bash, git, curl, jq, python3 with PyYAML.

```sh
make test                                       # offline tests + shellcheck
make build TARGETS=linux_arm64                  # newest stable release
make build TARGETS=linux_arm64 VERSION=1.104.4  # specific release
ls dist/linux_arm64/
```

See [docs/development.md](docs/development.md) for the build steps,
output files and repository layout.

## Adding a target

Targets are configuration only; the pipeline needs no changes. Add or enable
an entry in `platforms.yml`:

```yaml
  - os: linux
    arch: arm
    goarm: "7"        # architecture variant, part of the id: linux_arm_v7
    enabled: true
```

Then check it and try a local build:

```sh
python3 tools/platforms.py validate
make build TARGETS=linux_arm_v7
```

Per-OS defaults already handle the differences between systems. For example,
Linux gets a combined executable, while FreeBSD, macOS and Windows get
separate `tailscaled` and `tailscale` files. UPX is only offered for formats
and architectures it supports, and only Linux targets can run under QEMU in
CI. A target can override features, compression, size limits and validation.
See [docs/platforms.md](docs/platforms.md).

Defined targets: `linux_arm64` and `linux_amd64` are enabled. `linux_arm_v7`,
`linux_riscv64`, `freebsd_amd64` and `darwin_arm64` are defined but
disabled.

## Documentation

| Document | Contents |
|---|---|
| [docs/manifest.md](docs/manifest.md) | Download URLs, manifest format, compatibility rules, update-script guidance |
| [docs/self-update.md](docs/self-update.md) | Opt-in `tailscale update` / admin-console updates from Tinyscale releases |
| [docs/platforms.md](docs/platforms.md) | `platforms.yml` reference, default feature profile, measured sizes |
| [docs/ci.md](docs/ci.md) | Pipeline structure, variables, images and Dependency Proxy, Releases, retries |
| [docs/validation.md](docs/validation.md) | What each check proves, and its limitations |
| [docs/security.md](docs/security.md) | Source provenance, build integrity, CI permissions |
| [docs/development.md](docs/development.md) | Local builds, build steps, repository layout, conventions |

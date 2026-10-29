# `platforms.yml` reference

`tools/platforms.py` loads and validates `platforms.yml`, and resolves each
target into the JSON that the build scripts use. To check a change:

```sh
python3 tools/platforms.py validate          # whole file
python3 tools/platforms.py list --all        # target ids
python3 tools/platforms.py show linux_arm64  # fully resolved target
```

Unknown keys are errors. That catches typos such as `max_sise`.

## Layering

Each target is built up in three layers. Later layers win; mappings merge
recursively, and lists are **replaced**, not appended:

1. `defaults`
2. `os_defaults.<GOOS>`
3. the entry in `platforms`

## Top level

| Key | Description |
|---|---|
| `schema_version` | Must be `1`. |
| `defaults` | Settings for every target (target keys below, except `os`/`arch`). |
| `os_defaults` | Map of GOOS to settings for that OS. |
| `platforms` | List of targets. |

## Target keys

| Key | Type | Description |
|---|---|---|
| `os` | string | `GOOS` (required). |
| `arch` | string | `GOARCH` (required). |
| `goarm`, `goamd64`, `go386`, `gomips`, `gomips64`, `goarm64`, `goriscv64`, `goppc64` | string | Architecture variant. Only valid for the matching `GOARCH`, and at most one per target. It becomes part of the target id: `goarm: "7"` → `linux_arm_v7`, `goamd64: v3` → `linux_amd64_v3`, `gomips: softfloat` → `linux_mipsle_softfloat`. |
| `enabled` | bool | Whether CI builds the target. Disabled targets can still be built locally with `--targets`. |
| `combined` | bool | Embed the CLI in `tailscaled` (upstream `ts_include_cli`). Default is true only for Linux. When false, separate `tailscaled` and `tailscale` executables are built. |
| `features.mode` | `minimal` \| `full` | `minimal`: keep only `features.add` (plus upstream-declared dependencies). `full`: upstream's default feature set. |
| `features.add` | list | Features to keep in `minimal` mode. Must include `cli` when `combined: true`. |
| `features.remove` | list | Features to omit (either mode). Upstream refuses removals that break dependants. |
| `extra_tags` | list | Extra Go build tags. |
| `strip` | bool | Strip symbols and DWARF (`-s -w`). |
| `cgo` | bool | `CGO_ENABLED`. Default `false`. |
| `compression.enabled` | bool | Also produce a UPX-compressed copy. Rejected for formats and architectures UPX can't handle (Mach-O, PE, riscv64, …). |
| `compression.tool` | `upx` | Compressor. |
| `compression.args` | list | Compressor flags (default `--best --lzma`). |
| `validation.format` | `elf` \| `macho` \| `pe` | Expected container format. |
| `validation.static` | bool | Require no `PT_INTERP` or `DT_NEEDED` (ELF). |
| `validation.smoke_test` | `auto` \| `qemu` \| `native` \| `none` | `auto` means QEMU user-mode for Linux targets, otherwise `none`. A native host always runs natively. |
| `validation.max_size` | size | Limit for uncompressed executables (`40MiB`, `12000000`, `1.5GB`, or `null`). |
| `validation.max_compressed_size` | size | Limit for compressed executables. |
| `notes` | any | Free-form; ignored. |

## Feature names

Feature names are checked at build time against
`go run ./cmd/featuretags --list` from the exact upstream release. A release
that renames or removes a feature therefore fails loudly instead of silently
changing the binary. Upstream resolves dependencies: for example, keeping
`advertiseexitnode` also keeps `peerapiserver` and `advertiseroutes`.

## Examples

```yaml
# MIPS little-endian soft-float router target (UPX supports mipsle).
- os: linux
  arch: mipsle
  gomips: softfloat
  enabled: true
  validation:
    max_size: 40MiB

# Linux amd64 with userspace networking and Tailscale SSH.
- os: linux
  arch: amd64
  goamd64: v2
  enabled: true
  features:
    add: [cli, osrouter, nattraversal, portmapper, dns, useroutes, useexitnode,
          advertiseroutes, advertiseexitnode, ipnbus, health, tailnetlock,
          bakedroots, unixsocketidentity, iptables, sdnotify, resolved,
          netstack, ssh]

# Upstream's full feature set without Taildrop, built as separate binaries.
- os: freebsd
  arch: arm64
  enabled: true
  features:
    mode: full
    add: []
    remove: [taildrop]
  validation:
    smoke_test: none

# Windows (no UPX, no runtime test on Linux runners).
- os: windows
  arch: amd64
  enabled: true
  validation:
    smoke_test: none
```

Remember that `features.add` **replaces** the inherited list. Repeat every
feature you want to keep.

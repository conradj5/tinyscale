# Validation

`scripts/validate.sh` runs on every executable, both uncompressed and
compressed. It writes a JSON result that ends up in `metadata.json` and in
the report. Any failing check fails the build job, so `publish.sh` refuses to
upload. A skipped check is recorded with its reason.

| Check | What it verifies | Applies to |
|---|---|---|
| `format` | `file(1)` type; for ELF, `readelf -h` class, endianness, machine, executable type, and OS/ABI (Linux: System V or GNU; FreeBSD: FreeBSD) | all |
| `entry` | Entry point is non-zero and inside an executable `PT_LOAD` segment | ELF |
| `static` | No `PT_INTERP` and no `DT_NEEDED` entries | ELF with `validation.static: true` |
| `buildinfo` | `go version -m`: GOOS/GOARCH/variant, `CGO_ENABLED`, the exact build tags, main module `tailscale.com v<version>`, `vcs.revision` equal to the upstream commit, and `vcs.modified=false`; plus the stamped long version `<version>-t<commit9>` present in the binary | uncompressed |
| `size` | Against `max_size` / `max_compressed_size` | all |
| `upx` | `upx -t` integrity test | compressed |
| `smoke` | Runs `tailscaled --version` and, for the CLI or combined binary, `tailscale version` (combined binaries are invoked through a `tailscale` symlink). The first line must equal the version, and the reported commit must equal the upstream commit (no `-dirty`). | runnable targets |

SHA-256 checksums are recorded for every file. `publish.sh` checks the
`.sha256` file again before upload and reads every uploaded file back to
compare.

## How targets are executed

- **Native:** when the runner's OS and architecture match the target
  (linux/amd64 on GitLab SaaS runners).
- **QEMU user-mode:** for other Linux targets (`qemu-aarch64`, `qemu-arm
  -cpu max`, `qemu-riscv64`, …). The emulator is installed from Alpine and
  called directly, so no binfmt registration or privileged container is
  needed.
- **Not executed:** FreeBSD, macOS and Windows. GitLab's Linux runners can't
  run them, so `smoke_test` is set to `none` and only static checks apply.

## Known limitations

- The smoke test proves the binary loads, decompresses (UPX), starts the Go
  runtime, and reports the right version and commit. It does **not** create
  a TUN device, change routes, or connect to a coordination server. That
  needs privileges and credentials CI shouldn't have.
- QEMU user-mode emulates the CPU, not the target kernel. It won't catch
  problems such as a kernel too old for Go's minimum requirements or missing
  netfilter modules.
- `GOARM=7` binaries are run with `-cpu max`. The test does not prove they
  run on a minimal ARMv7 core without NEON/VFPv4 (Go's `GOARM=7` needs
  VFPv3).
- Removed features are not tested for the absence of their behaviour. The
  exact tag set is recorded and verified through `buildinfo`.
- The entry-point check is ELF-only. For Mach-O and PE, the format check
  (via `file`) and `buildinfo` are the main assurances.
- UPX output is integrity-tested and executed, but some security products
  flag UPX-packed executables. The uncompressed file is always published
  too.
- UPX executables unpack into RAM at startup, costing roughly their
  uncompressed size in memory that can't be reclaimed. On devices short of
  RAM, use the uncompressed file.

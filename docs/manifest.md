# Download interface and manifest

This is the stable interface for anything that downloads Tinyscale
builds: update scripts on routers, provisioning tools, or people. It covers
the download URLs, the per-target manifest, and the compatibility rules.
Consumers should rely only on what this page describes.

## Download URLs

Every published version has a GitLab Release tagged `v<VERSION>`. Its files
are reachable under two version-independent patterns:

```
<project URL>/-/releases/permalink/latest/downloads/<path>   newest Release
<project URL>/-/releases/v<VERSION>/downloads/<path>          a specific version
```

`<project URL>` is the GitLab project's web address, for example
`https://gitlab.example.com/group/tinyscale`. Both patterns answer with
an HTTP redirect to the file, so clients must follow redirects (`curl -L`;
BusyBox and OpenWrt `wget` follow them by default). Public projects need no
credentials. For a private project, send a token that can read the project,
such as `PRIVATE-TOKEN: <token>` or a deploy token.

### Paths

`<target>` is a target id from `platforms.yml`, for example `linux_arm64`
or `linux_arm_v7` (see [platforms.md](platforms.md)).

| Path | Content |
|---|---|
| `<target>.manifest` | Manifest (below) |
| `<target>` | Uncompressed executable (combined targets) |
| `<target>.upx` | UPX-compressed executable (combined targets with compression enabled) |
| `<target>.tailscaled`, `<target>.tailscale` | Separate executables (targets with `combined: false`) |
| `<target>.tailscaled.upx`, `<target>.tailscale.upx` | Their compressed copies, if compression is enabled |
| `<target>.sha256` | `sha256sum`-format checksums (`<hex>  <file name>`) of every executable |
| `<target>.metadata.json` | Full build and validation metadata (informational; its schema may change) |
| `<target>.report.md` | Human-readable size and validation report (informational) |

Windows executables keep their extension: `<target>.tailscaled.exe`,
`<target>.tailscale.exe`. The manifest's `*_FILE` values always give the
exact file names, so a consumer never has to guess.

### Package Registry

The same files are stored in the project's Generic Package Registry,
package `tailscale-tiny`, version `<VERSION>`, under the file names listed
in the manifest:

```
<API URL>/projects/<project id>/packages/generic/tailscale-tiny/<VERSION>/<file name>
```

A package version may exist briefly without a Release while a pipeline is
still publishing other targets. The Release only appears once every enabled
target is complete, so prefer the Release URLs.

## Manifest format

The manifest is plain text so that BusyBox shell scripts can read it
without a JSON parser:

```
FORMAT=1
VERSION=1.104.4
TAG=v1.104.4
COMMIT=27047635f237d1f3e0b08c0f487674757f30d2f7
TARGET=linux_arm64
SELF_UPDATE=0
BIN_FILE=tailscale-tiny_1.104.4_linux_arm64
BIN_SHA256=bf7f92cab3e5c980e39aa5b5a81d05f8c340d7b74dc79f0baa6101e201ee64cd
BIN_SIZE=15728800
BIN_UPX_FILE=tailscale-tiny_1.104.4_linux_arm64.upx
BIN_UPX_SHA256=49df1932b22bdb780e3f7475c969a66081e4930a5e072c21b0cc9342595d99f3
BIN_UPX_SIZE=4207380
```

Syntax:

- ASCII, LF line endings, one `KEY=value` per line.
- Keys match `[A-Z0-9_]+`. Values contain no spaces, quotes or `=`.
- The first line is always `FORMAT=<n>`. Other lines may appear in any
  order.

### Keys

Always present:

| Key | Meaning |
|---|---|
| `FORMAT` | Manifest format version; currently `1`. |
| `VERSION` | Upstream Tailscale version, `MAJOR.MINOR.PATCH` (always a stable release). |
| `TAG` | Upstream and Release tag, `v<VERSION>`. |
| `COMMIT` | Full 40-character upstream commit the build was made from. |
| `TARGET` | Target id, the same as `<target>` in the paths. |
| `SELF_UPDATE` | `1` if `tailscale update` in this build installs Tinyscale releases ([self-update.md](self-update.md)), otherwise `0`. |

Per executable, each with a `_FILE` (file name), `_SHA256` (lowercase hex
SHA-256) and `_SIZE` (bytes) key:

| Prefix | Present for |
|---|---|
| `BIN` | Combined targets: the uncompressed combined executable. Keys: `BIN_FILE`, `BIN_SHA256`, `BIN_SIZE`. |
| `BIN_UPX` | Combined targets with compression: `BIN_UPX_FILE`, `BIN_UPX_SHA256`, `BIN_UPX_SIZE`. |
| `TAILSCALED` | Separate executables: `TAILSCALED_FILE`, `TAILSCALED_SHA256`, `TAILSCALED_SIZE`. |
| `TAILSCALED_UPX` | Their compressed copy: `TAILSCALED_UPX_FILE`, `TAILSCALED_UPX_SHA256`, `TAILSCALED_UPX_SIZE`. |
| `TAILSCALE` | Separate CLI: `TAILSCALE_FILE`, `TAILSCALE_SHA256`, `TAILSCALE_SIZE`. |
| `TAILSCALE_UPX` | Its compressed copy: `TAILSCALE_UPX_FILE`, `TAILSCALE_UPX_SHA256`, `TAILSCALE_UPX_SIZE`. |

A `*_UPX_*` group exists only when the target has compression enabled, so
check for it before using it.

## Compatibility rules

Within `FORMAT=1`:

- Keys listed above are never removed or renamed, and their meaning never
  changes.
- New keys may be added. Consumers must ignore keys they don't know.
- The download paths above keep working for every published version.

A change that breaks any of this increases `FORMAT`. Consumers should
refuse to act on a manifest whose `FORMAT` they don't support, rather than
guess.

## Using it from an update script

1. Fetch `permalink/latest/downloads/<target>.manifest`.
2. Check `FORMAT=1` and `TARGET`, then compare `VERSION` with the installed
   version (`tailscale version`, first line).
3. Download the executable from the **pinned** path
   `v<VERSION>/downloads/<target>[.upx]`, not from `permalink/latest`. A new
   Release could be published between the two requests, and the pinned path
   guarantees the file matches the manifest you read.
4. Verify its SHA-256 against `BIN_SHA256` (or `BIN_UPX_SHA256`) before
   installing it.

Read values with `grep '^KEY=' | cut -d= -f2`. Never `source` or `eval` a
downloaded file.

```sh
url=https://gitlab.example.com/group/tinyscale/-/releases
target=linux_arm64
wget -qO /tmp/tt.manifest "$url/permalink/latest/downloads/$target.manifest"
get() { grep "^$1=" /tmp/tt.manifest | cut -d= -f2; }
[ "$(get FORMAT)" = 1 ] && [ "$(get TARGET)" = "$target" ] || exit 1
ver=$(get VERSION)
[ "$ver" = "$(tailscale version | head -n1)" ] && exit 0      # up to date
wget -qO /tmp/tailscaled.new "$url/v$ver/downloads/$target.upx"
echo "$(get BIN_UPX_SHA256)  /tmp/tailscaled.new" | sha256sum -c - || exit 1
```

### Installing a combined executable

The combined executable runs as `tailscaled` by default and as the CLI when
it is invoked under the name `tailscale`:

```sh
install -m 0755 /tmp/tailscaled.new /usr/sbin/tailscaled
ln -sf tailscaled /usr/sbin/tailscale
```

Stop the service before replacing the file, and back up the state file
first: an older Tailscale may not read state written by a newer one.

### Compressed or uncompressed?

The UPX copy is about a quarter of the size on disk, but it unpacks itself
into RAM at startup. That memory can't be reclaimed or paged back to flash,
so it costs roughly the uncompressed size in RAM (about 15 MiB for
`linux_arm64`). Prefer the uncompressed file on devices short of RAM, and
the UPX file on devices short of flash.

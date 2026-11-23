# Self-update

With `self_update: true` on a target in `platforms.yml`, the built
executable's `tailscale update` installs Tinyscale releases instead of
official Tailscale packages. tailscaled runs that same command for updates
started from the admin console's **Update** button and for automatic
updates, so all three paths use this project's builds.

Linux targets with a combined executable enable it by default. A target
can opt out with `self_update: false`.

## How it works

Upstream Tailscale keeps all update logic in its `clientupdate` feature,
which Tinyscale normally leaves out. Every way of starting an update
ends in tailscaled running `tailscale update --yes`. Upstream's version of
that command downloads official packages signed with Tailscale's keys,
which can't work for our builds.

For a `self_update` target, the build:

1. Adds upstream's `clientupdate` feature, so tailscaled reports that it can
   be updated and accepts update requests from the control server
   (about +110 KB UPX-compressed).
2. Adds one file, `overlay/cmd/tailscale/cli/zz_tinyupdate.go`, to upstream's
   `cmd/tailscale/cli` package with `go build -overlay`, plus a small
   generated file holding the target id and the releases URL. No upstream
   file is modified; the fetched source still matches the release tag and
   build info still reports `vcs.modified=false`.
3. Runs the overlay's Go tests before building, and the smoke test checks
   that the built executable's `tailscale update` is the Tinyscale one.

The replacement `tailscale update`:

1. Reads [the target manifest](manifest.md) from GitLab's
   `/permalink/latest/downloads/<target>.manifest` or public GitHub's
   `/latest/download/<target>.manifest`. With `--version`, it fetches the
   manifest from the requested tag.
2. Does nothing if the running version is the same or newer (unless
   `--version` is given).
3. Downloads from the pinned `v<version>` path, keeping the installed
   variant (UPX or uncompressed), and checks the size and SHA-256.
   GitHub assets use the binary filename in the manifest.
4. Runs the new executable with `--version` and requires the expected
   version. This also proves it runs on the device's CPU and, for UPX, that
   it unpacks in the memory available.
5. Keeps the previous executable as `<path>.old` (a hard link, so no extra
   space), atomically replaces the executable, and restarts tailscaled via
   systemd (`tailscaled.service`) or `/etc/init.d/*tailscale`.
6. Deletes `<path>.old` once the restart succeeds. If there's no service
   to restart, or the restart fails, it keeps the file for a manual
   rollback.

Flags: `--yes`, `--dry-run`, `--version X.Y.Z`.

Every step and any error also goes to the system log with the tag
`tailscale-update` (via `logger`; dry runs are not logged). That's the
record to check for remotely started updates: tailscaled only logs the
command's output once it exits, and the restart stops that tailscaled
first. To follow an update on the device:

```sh
logread -f | grep -e tailscale-update -e 'c2n:'            # OpenWrt
journalctl -f -t tailscale-update -u tailscaled            # systemd
```

The upstream source has a separate, in-process update path used only by
desktop GUI clients. It isn't replaced and would install official packages.
Headless Linux devices don't use it.

## Configuration

The releases URL is compiled in: `TT_UPDATE_URL` at build time, or
`<CI_PROJECT_URL>/-/releases` in CI. At runtime these environment variables
override it. Set them for tailscaled, because remote updates inherit
tailscaled's environment.

| Variable | Meaning |
|---|---|
| `TT_UPDATE_URL` | Releases base URL, e.g. `https://gitlab.example.com/group/tinyscale/-/releases` or `https://github.com/OWNER/REPO/releases`. |
| `TT_UPDATE_TOKEN_FILE` | File containing a GitLab token, sent as `PRIVATE-TOKEN` (only to the URL's host, never to redirect targets). Needed when the project isn't public. |
| `TS_ALLOW_ADMIN_CONSOLE_REMOTE_UPDATE` | Upstream setting: `true` allows updates from the admin console. Alternatively run `tailscale set --auto-update`. |

GitHub Actions compiles in the public GitHub Releases URL. GitHub updates
require a published release with a `<target>.manifest` asset and the named
binaries. Actions run artifacts alone do not provide these endpoints.

### GitLab projects that aren't public

A project is only as visible as its parent groups: if any of them is
internal or private, anonymous downloads redirect to `/users/sign_in`, and
the updater reports that the project isn't public. Either make the project
and its groups public, or give devices read access with a token:

1. Create a **project access token** (*Settings › Access tokens*) with the
   **Reporter** role and the `read_api` scope, with an expiry date.
2. Store it on the device in a file readable only by root (`chmod 600`).
3. Point the updater at the API form of the releases URL, which accepts the
   token. Use the numeric project id or the URL-encoded path:

   ```
   TT_UPDATE_URL=https://gitlab.example.com/api/v4/projects/<id>/releases
   TT_UPDATE_TOKEN_FILE=/etc/tailscale/tiny-update.token
   ```

   The path structure after `/releases` is the same as on the web.

Check it from the device before relying on it:

```sh
curl -fsSL -H "PRIVATE-TOKEN: $(cat /etc/tailscale/tiny-update.token)" \
  "$TT_UPDATE_URL/permalink/latest/downloads/linux_arm64.manifest"
```

A token on a device can be read by anyone who gains root on it. Limit it to
`read_api`, the Reporter role and this one project, and give it an expiry.

## Enabling it on a device

1. Install a build with `SELF_UPDATE=1` in its manifest.
2. Make sure `/usr/bin/tailscale` exists. When tailscaled is installed as
   `/usr/sbin/tailscaled`, upstream looks for the CLI only at that path, so
   systems that keep it in `/usr/sbin` need
   `ln -s /usr/sbin/tailscaled /usr/bin/tailscale`.
3. Opt in, and configure the URL and token if needed, in tailscaled's
   environment (systemd unit, init script, or `/etc/default/tailscaled`).
   For example, in a procd init script:

   ```sh
   procd_set_param env TS_DEBUG_FIREWALL_MODE=auto \
       TS_ALLOW_ADMIN_CONSOLE_REMOTE_UPDATE=true \
       TT_UPDATE_URL=https://gitlab.example.com/api/v4/projects/<id>/releases \
       TT_UPDATE_TOKEN_FILE=/etc/tailscale/tiny-update.token
   ```

   Restart tailscaled afterwards.
4. Test with `tailscale update --dry-run`.

## Limitations

- **Admin console behaviour isn't guaranteed.** Everything on the device
  side is upstream's own code, but Tailscale's control server and admin
  console are closed source and may apply rules of their own before showing
  the Update button. `tailscale update` and auto-updates work regardless.
  When a device updated from the admin console to a build without
  `self_update`, the update was installed but the console reported
  "Failed", most likely because the new tailscaled can't answer the
  console's status check. Keep `self_update` enabled on targets whose
  devices update this way.
- **Short delay after upstream releases.** The admin console offers an
  update as soon as Tailscale publishes one; Tinyscale builds it on its
  next scheduled run. In between, `tailscale update` reports the device as
  up to date.
- **No automatic rollback.** The new executable is tested before it's
  installed, but if tailscaled then fails to start, nothing reverts it. A
  successful restart only means the service manager accepted the command,
  and `<path>.old` is gone by then. Back up the executable yourself before
  updating if you need a guaranteed rollback.
- **Unsigned.** Integrity rests on HTTPS to the release host and the
  manifest's SHA-256 ([security.md](security.md)).
- **Depends on upstream internals.** The overlay uses one unexported
  variable in upstream's CLI package (`maybeUpdateCmd`). If upstream changes
  it, the build fails with a compile error until the overlay is adjusted.
- **Running under QEMU.** The overlay's Go tests and the smoke test run in
  CI, but QEMU user mode can't run the downloaded executable for the version
  check, so a full update can only be exercised natively or on a device.

# Security and provenance

## Source

- Release metadata comes from the GitHub API, which only selects the
  version. The tag-to-commit mapping is resolved separately with
  `git ls-remote`, checked again after the fetch, and `VERSION.txt` in the
  fetched tree must match.
- Only `refs/tags/vX.Y.Z` is fetched, at depth 1. The development branch is
  never used. Drafts, prereleases, release candidates and odd (unstable)
  minor versions are rejected.
- Go modules are verified against upstream's `go.sum` and the Go checksum
  database (`-mod=readonly`). `GOTOOLCHAIN=local` stops Go from silently
  downloading a different toolchain.
- The build image is the official `golang` image for the Go version in
  upstream's `go.mod`.

## Build output

- Every executable's build info records the module version, upstream
  commit, `vcs.modified=false`, target and exact build tags; validation
  checks all of them ([validation.md](validation.md)).
- Builds are reproducible, so anyone can rebuild a version and compare
  SHA-256 sums.
- Checksums are published with every file, and the manifest carries them
  for device-side verification ([manifest.md](manifest.md)).

## CI

- Publishing uses `CI_JOB_TOKEN`; no long-lived secret is stored. The token
  is passed to curl in a config file, not on the command line, and is never
  sent to redirect targets such as object storage.
- The optional `GITHUB_TOKEN` only raises the GitHub API rate limit and
  needs no permissions.
- No privileged containers and no Docker socket are used. QEMU runs in user
  mode, called directly without binfmt registration.
- Nothing is ever deployed. Devices decide for themselves when to download
  and install a build. Targets with `self_update` add an updater to the
  binary, which only runs when the device opts in
  ([self-update.md](self-update.md)).

## Not covered

- Published files are not signed. Their integrity rests on HTTPS to the
  GitLab instance and the published SHA-256 sums.
- macOS executables are ad-hoc signed by the Go linker but not notarized.
- Some security products flag UPX-packed executables. The uncompressed
  file is always published as well.

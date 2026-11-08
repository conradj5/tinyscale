// Tinyscale self-update.
//
// This file is not part of upstream Tailscale. Tinyscale adds it to
// upstream's cmd/tailscale/cli package at build time with `go build -overlay`
// for targets with `self_update: true` in platforms.yml; no upstream file is
// modified. See docs/self-update.md.
//
// It replaces the `tailscale update` command. tailscaled runs that command
// for admin-console and automatic updates too, so all of them install
// Tinyscale releases (docs/manifest.md) instead of official packages.
//
// The file name sorts after upstream's update.go, so this init runs last and
// its maybeUpdateCmd wins.

//go:build linux

package cli

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/peterbourgon/ff/v3/ffcli"
	"tailscale.com/util/cmpver"
	"tailscale.com/version"
)

func init() {
	maybeUpdateCmd = func() *ffcli.Command { return tinyUpdateCmd }
}

var tinyUpdateArgs struct {
	yes     bool
	dryRun  bool
	version string
	track   string
}

var tinyUpdateCmd = &ffcli.Command{
	Name:       "update",
	ShortUsage: "tailscale update [--yes] [--dry-run] [--version X.Y.Z]",
	ShortHelp:  "Update Tailscale from Tinyscale releases",
	LongHelp: strings.TrimSpace(`
Installs the newest Tinyscale release for this target, or the version
given with --version, in place of the running executable, then restarts
tailscaled.

Configuration (environment of tailscaled and of this command):
  TT_UPDATE_URL          releases base URL (default compiled in: ` + tinyUpdateDefaultURL + `)
  TT_UPDATE_TOKEN_FILE   file holding a GitLab token for non-public projects
`),
	FlagSet: (func() *flag.FlagSet {
		fs := flag.NewFlagSet("update", flag.ContinueOnError)
		fs.BoolVar(&tinyUpdateArgs.yes, "yes", false, "update without interactive prompts")
		fs.BoolVar(&tinyUpdateArgs.dryRun, "dry-run", false, "print what update would do without doing it")
		fs.StringVar(&tinyUpdateArgs.version, "version", "", "explicit version to install (also allows reinstalling or downgrading)")
		fs.StringVar(&tinyUpdateArgs.track, "track", "", `accepted for compatibility; only "stable" exists`)
		return fs
	})(),
	Exec: runTinyUpdate,
}

func runTinyUpdate(ctx context.Context, args []string) error {
	if len(args) > 0 {
		return flag.ErrHelp
	}
	if t := tinyUpdateArgs.track; t != "" && t != "stable" {
		return fmt.Errorf("Tinyscale only publishes the stable track, not %q", t)
	}
	base, token, err := tinyUpdateConfig(os.Getenv)
	if err != nil {
		return err
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	if exe, err = filepath.EvalSymlinks(exe); err != nil {
		return err
	}
	// When tailscaled runs this command, stdout is a pipe to tailscaled, which
	// the restart at the end of an update stops. Writing to it must then fail
	// quietly instead of killing this process with SIGPIPE.
	signal.Ignore(syscall.SIGPIPE)
	u := &tinyUpdater{
		base:    base,
		token:   token,
		target:  tinyUpdateTarget,
		current: version.Short(),
		exe:     exe,
		out:     os.Stdout,
		confirm: tinyConfirm,
		verify:  tinyVerifyBinary,
		restart: tinyRestartService,
		isRoot:  func() bool { return os.Geteuid() == 0 },
	}
	if !tinyUpdateArgs.dryRun {
		u.syslog = tinySyslogger()
	}
	return u.run(tinyUpdateArgs.version, tinyUpdateArgs.dryRun)
}

// tinySyslogger returns a function that sends a message to the system log
// with logger(1), or nil if there is no logger. tailscaled only logs this
// command's output once it exits, and the restart at the end of an update
// stops that tailscaled first, so for a remotely started update the system
// log is the only record of what happened.
func tinySyslogger() func(string) {
	path, err := exec.LookPath("logger")
	if err != nil {
		for _, p := range []string{"/usr/bin/logger", "/bin/logger"} {
			if fi, err := os.Stat(p); err == nil && fi.Mode().IsRegular() {
				path = p
				break
			}
		}
	}
	if path == "" {
		return nil
	}
	return func(msg string) {
		exec.Command(path, "-t", "tailscale-update", "-p", "daemon.notice", "--", msg).Run()
	}
}

// tinyUpdateConfig returns the releases base URL (no trailing slash) and the
// optional token.
func tinyUpdateConfig(getenv func(string) string) (base, token string, err error) {
	base = getenv("TT_UPDATE_URL")
	if base == "" {
		base = tinyUpdateDefaultURL
	}
	if base == "" {
		return "", "", errors.New("no update URL: this build has none compiled in; set TT_UPDATE_URL")
	}
	pu, err := url.Parse(base)
	if err != nil || pu.Host == "" {
		return "", "", fmt.Errorf("invalid TT_UPDATE_URL %q", base)
	}
	if pu.Scheme != "https" && !(pu.Scheme == "http" && getenv("TT_UPDATE_ALLOW_HTTP") == "1") {
		return "", "", fmt.Errorf("TT_UPDATE_URL must use https: %q", base)
	}
	if f := getenv("TT_UPDATE_TOKEN_FILE"); f != "" {
		b, err := os.ReadFile(f)
		if err != nil {
			return "", "", fmt.Errorf("reading TT_UPDATE_TOKEN_FILE: %w", err)
		}
		token = strings.TrimSpace(string(b))
	}
	return strings.TrimRight(base, "/"), token, nil
}

type tinyUpdater struct {
	base    string // e.g. https://gitlab.example.com/group/tinyscale/-/releases
	token   string // sent as PRIVATE-TOKEN to the base URL's host only
	target  string // target id, e.g. linux_arm64
	current string // running version, X.Y.Z
	exe     string // resolved path of the running executable
	out     io.Writer
	syslog  func(msg string) // nil: no system log
	client  *http.Client

	confirm func(newVersion string) bool
	verify  func(path string) (string, error) // version reported by an executable
	restart func() error                      // errTinyNoService if there is none
	isRoot  func() bool                       // nil skips the check (tests)
}

var (
	tinyVersionRE    = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)
	errTinyNoService = errors.New("no tailscaled service found")
)

const tinyManifestLimit = 64 << 10

// logf writes to the system log first: stdout may be a pipe to a tailscaled
// that the update has just stopped.
func (u *tinyUpdater) logf(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	if u.syslog != nil {
		u.syslog(msg)
	}
	fmt.Fprintln(u.out, msg)
}

func (u *tinyUpdater) run(wantVersion string, dryRun bool) (retErr error) {
	defer func() {
		if retErr != nil && u.syslog != nil {
			u.syslog("Update failed: " + retErr.Error())
		}
	}()
	if wantVersion != "" && !tinyVersionRE.MatchString(wantVersion) {
		return fmt.Errorf("invalid --version %q", wantVersion)
	}
	manifestPath := "/permalink/latest/downloads/" + u.target + ".manifest"
	if wantVersion != "" {
		manifestPath = "/v" + wantVersion + "/downloads/" + u.target + ".manifest"
	}
	m, err := u.fetchManifest(u.base + manifestPath)
	if err != nil {
		return err
	}
	newVer := m["VERSION"]
	if wantVersion != "" && newVer != wantVersion {
		return fmt.Errorf("manifest for v%s reports version %s", wantVersion, newVer)
	}
	if wantVersion == "" && cmpver.Compare(newVer, u.current) <= 0 {
		u.logf("Already running Tailscale %s; newest Tinyscale release is %s.", u.current, newVer)
		return nil
	}

	// Keep the variant that is installed: UPX-packed or uncompressed.
	key, suffix := "BIN", ""
	if tinyIsUPX(u.exe) {
		if m["BIN_UPX_FILE"] != "" {
			key, suffix = "BIN_UPX", ".upx"
		} else {
			u.logf("Release %s has no UPX copy for %s; installing the uncompressed executable.", newVer, u.target)
		}
	}
	wantSHA, sizeStr := m[key+"_SHA256"], m[key+"_SIZE"]
	size, err := strconv.ParseInt(sizeStr, 10, 64)
	if err != nil || size <= 0 || len(wantSHA) != 64 {
		return fmt.Errorf("manifest is missing a valid %s_SHA256/%s_SIZE", key, key)
	}
	fileURL := u.base + "/v" + newVer + "/downloads/" + u.target + suffix

	if dryRun {
		u.logf("Current: %s, latest: %s. Would install %s (%d bytes) to %s.", u.current, newVer, fileURL, size, u.exe)
		return nil
	}
	if !u.confirm(newVer) {
		return nil
	}
	if u.isRoot != nil && !u.isRoot() {
		return errors.New("must be run as root to replace " + u.exe)
	}

	u.logf("Downloading %s", fileURL)
	tmp, err := u.download(fileURL, filepath.Dir(u.exe), size, wantSHA)
	if err != nil {
		return err
	}
	defer os.Remove(tmp) // no-op after the rename below

	got, err := u.verify(tmp)
	if err != nil {
		return fmt.Errorf("downloaded executable does not run on this device: %w", err)
	}
	if got != newVer {
		return fmt.Errorf("downloaded executable reports version %q, expected %s", got, newVer)
	}

	// Keep the previous executable for manual rollback until tailscaled has
	// restarted on the new one. A hard link costs no space; if it isn't
	// possible, continue without a backup.
	backup := u.exe + ".old"
	os.Remove(backup)
	backedUp := true
	if err := os.Link(u.exe, backup); err != nil {
		u.logf("Note: could not keep the previous executable as %s: %v", backup, err)
		backedUp = false
	}
	if err := os.Rename(tmp, u.exe); err != nil {
		return fmt.Errorf("installing %s: %w", u.exe, err)
	}
	u.logf("Installed Tailscale %s to %s.", newVer, u.exe)

	kept := ""
	if backedUp {
		kept = " The previous executable is kept as " + backup + "."
	}
	switch err := u.restart(); {
	case errors.Is(err, errTinyNoService):
		u.logf("Restart tailscaled to finish the update.%s", kept)
	case err != nil:
		u.logf("Updated, but restarting tailscaled failed: %v. Restart it to finish the update.%s", err, kept)
	default:
		u.logf("Restarted tailscaled.")
		// The backup is only for rollback; once the new executable is
		// running it would just take up space.
		if backedUp {
			if err := os.Remove(backup); err != nil {
				u.logf("Note: could not remove %s: %v", backup, err)
			}
		}
	}
	return nil
}

func (u *tinyUpdater) httpClient() *http.Client {
	if u.client != nil {
		return u.client
	}
	return &http.Client{Timeout: 10 * time.Minute}
}

func (u *tinyUpdater) get(rawURL string) (*http.Response, error) {
	baseURL, err := url.Parse(u.base)
	if err != nil {
		return nil, err
	}
	c := *u.httpClient()
	c.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) >= 10 {
			return errors.New("too many redirects")
		}
		if via[0].URL.Scheme == "https" && req.URL.Scheme != "https" {
			return fmt.Errorf("refusing redirect from https to %s", req.URL.Redacted())
		}
		// The token is only for the GitLab instance, never for redirect
		// targets such as object storage.
		if req.URL.Host != baseURL.Host {
			req.Header.Del("PRIVATE-TOKEN")
		}
		return nil
	}
	req, err := http.NewRequest("GET", rawURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "tinyscale-update/"+u.current)
	if u.token != "" {
		req.Header.Set("PRIVATE-TOKEN", u.token)
	}
	res, err := c.Do(req)
	if err != nil {
		return nil, err
	}
	if strings.HasSuffix(res.Request.URL.Path, "/users/sign_in") {
		res.Body.Close()
		return nil, fmt.Errorf("%s requires signing in: the project is not public; set TT_UPDATE_URL to the API releases URL and TT_UPDATE_TOKEN_FILE (see docs/self-update.md)", rawURL)
	}
	if res.StatusCode != http.StatusOK {
		res.Body.Close()
		return nil, fmt.Errorf("GET %s: %s", rawURL, res.Status)
	}
	return res, nil
}

func (u *tinyUpdater) fetchManifest(rawURL string) (map[string]string, error) {
	res, err := u.get(rawURL)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	body, err := io.ReadAll(io.LimitReader(res.Body, tinyManifestLimit+1))
	if err != nil {
		return nil, err
	}
	if len(body) > tinyManifestLimit {
		return nil, fmt.Errorf("manifest at %s is too large", rawURL)
	}
	return parseTinyManifest(body, u.target)
}

// parseTinyManifest parses and checks a FORMAT=1 manifest (docs/manifest.md).
func parseTinyManifest(body []byte, target string) (map[string]string, error) {
	m := map[string]string{}
	sc := bufio.NewScanner(bytes.NewReader(body))
	first := true
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if line == "" {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			return nil, errors.New("not a Tinyscale manifest")
		}
		if first {
			if k != "FORMAT" {
				return nil, errors.New("not a Tinyscale manifest")
			}
			if v != "1" {
				return nil, fmt.Errorf("unsupported manifest FORMAT=%s; this updater understands FORMAT=1", v)
			}
			first = false
		}
		m[k] = v
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if first {
		return nil, errors.New("empty manifest")
	}
	if m["TARGET"] != target {
		return nil, fmt.Errorf("manifest is for target %q, this executable is %q", m["TARGET"], target)
	}
	if !tinyVersionRE.MatchString(m["VERSION"]) {
		return nil, fmt.Errorf("manifest has invalid VERSION %q", m["VERSION"])
	}
	return m, nil
}

// download saves rawURL to a new file in dir, checking its size and SHA-256.
func (u *tinyUpdater) download(rawURL, dir string, size int64, wantSHA string) (path string, err error) {
	res, err := u.get(rawURL)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	f, err := os.CreateTemp(dir, ".tailscaled.tiny-update.*")
	if err != nil {
		return "", err
	}
	defer func() {
		f.Close()
		if err != nil {
			os.Remove(f.Name())
		}
	}()
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(f, h), io.LimitReader(res.Body, size+1))
	if err != nil {
		return "", fmt.Errorf("downloading %s: %w", rawURL, err)
	}
	if n != size {
		return "", fmt.Errorf("downloaded %d bytes from %s, manifest says %d", n, rawURL, size)
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != strings.ToLower(wantSHA) {
		return "", fmt.Errorf("SHA-256 mismatch for %s: got %s, manifest says %s", rawURL, got, wantSHA)
	}
	if err := f.Chmod(0o755); err != nil {
		return "", err
	}
	if err := f.Close(); err != nil {
		return "", err
	}
	return f.Name(), nil
}

// tinyIsUPX reports whether path is a UPX-packed executable.
func tinyIsUPX(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	head := make([]byte, 4096)
	n, _ := io.ReadFull(f, head)
	return bytes.Contains(head[:n], []byte("UPX!"))
}

// tinyVerifyBinary runs the new executable as tailscaled and returns the
// version it reports. This also proves it runs on this CPU and, for UPX
// copies, that it unpacks in the memory available.
func tinyVerifyBinary(path string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	out, err := exec.CommandContext(ctx, path, "--version").Output()
	if err != nil {
		return "", err
	}
	first, _, _ := strings.Cut(string(out), "\n")
	return strings.TrimSpace(first), nil
}

// tinyRestartService restarts tailscaled through systemd or an init.d
// script. The restart runs in its own session so that it completes even if
// stopping tailscaled also stops this process (tailscaled runs `tailscale
// update` for admin-console and automatic updates).
func tinyRestartService() error {
	run := func(name string, args ...string) error {
		cmd := exec.Command(name, args...)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, bytes.TrimSpace(out))
		}
		return nil
	}
	if _, err := exec.LookPath("systemctl"); err == nil &&
		exec.Command("systemctl", "is-active", "--quiet", "tailscaled.service").Run() == nil {
		return run("systemctl", "restart", "tailscaled.service")
	}
	scripts, _ := filepath.Glob("/etc/init.d/*tailscale")
	for _, s := range scripts {
		if fi, err := os.Stat(s); err == nil && fi.Mode().IsRegular() && fi.Mode()&0o111 != 0 {
			return run(s, "restart")
		}
	}
	return errTinyNoService
}

func tinyConfirm(newVersion string) bool {
	if tinyUpdateArgs.yes {
		fmt.Printf("Updating Tailscale from %s to %s (Tinyscale); --yes given, continuing without prompts.\n", version.Short(), newVersion)
		return true
	}
	fmt.Printf("This will update Tailscale from %s to %s (Tinyscale). Continue? [y/N] ", version.Short(), newVersion)
	line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
	switch strings.ToLower(strings.TrimSpace(line)) {
	case "y", "yes":
		return true
	}
	return false
}

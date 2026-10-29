// Tests for the Tinyscale self-update overlay (zz_tinyupdate.go). Run by
// scripts/build-target.sh before building a target with self_update: true.

//go:build linux

package cli

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

type tinyTestRelease struct {
	version string
	plain   []byte
	upx     []byte
}

func tinySum(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

func (r tinyTestRelease) manifest(target string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "FORMAT=1\nVERSION=%s\nTAG=v%[1]s\nCOMMIT=%040d\nTARGET=%s\n", r.version, 0, target)
	fmt.Fprintf(&b, "BIN_FILE=x\nBIN_SHA256=%s\nBIN_SIZE=%d\n", tinySum(r.plain), len(r.plain))
	if r.upx != nil {
		fmt.Fprintf(&b, "BIN_UPX_FILE=x.upx\nBIN_UPX_SHA256=%s\nBIN_UPX_SIZE=%d\nNEW_KEY=ignored\n", tinySum(r.upx), len(r.upx))
	}
	return b.String()
}

type tinyTestServer struct {
	*httptest.Server
	mu       sync.Mutex
	releases map[string]tinyTestRelease // by version
	latest   string
	requests []string // paths, with "+token" when PRIVATE-TOKEN was sent
	override map[string]string
}

func newTinyTestServer(t *testing.T, latest string, rels ...tinyTestRelease) *tinyTestServer {
	s := &tinyTestServer{releases: map[string]tinyTestRelease{}, latest: latest, override: map[string]string{}}
	for _, r := range rels {
		s.releases[r.version] = r
	}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		p := r.URL.Path
		if r.Header.Get("PRIVATE-TOKEN") != "" {
			s.requests = append(s.requests, p+"+token")
		} else {
			s.requests = append(s.requests, p)
		}
		if body, ok := s.override[p]; ok {
			fmt.Fprint(w, body)
			return
		}
		const target = "linux_test"
		rest, ok := strings.CutPrefix(p, "/rel/")
		if !ok {
			http.NotFound(w, r)
			return
		}
		ver, file, _ := strings.Cut(rest, "/downloads/")
		if ver == "permalink/latest" {
			ver = "v" + s.latest
		}
		rel, ok := s.releases[strings.TrimPrefix(ver, "v")]
		if !ok {
			http.NotFound(w, r)
			return
		}
		switch file {
		case target + ".manifest":
			fmt.Fprint(w, rel.manifest(target))
		case target:
			w.Write(rel.plain)
		case target + ".upx":
			w.Write(rel.upx)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

func (s *tinyTestServer) paths() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return strings.Join(s.requests, " ")
}

type tinyTestEnv struct {
	u         *tinyUpdater
	out       *bytes.Buffer
	restarted bool
}

func newTinyTestEnv(t *testing.T, srv *tinyTestServer, current string, installed []byte) *tinyTestEnv {
	dir := t.TempDir()
	exe := filepath.Join(dir, "tailscaled")
	if err := os.WriteFile(exe, installed, 0o755); err != nil {
		t.Fatal(err)
	}
	env := &tinyTestEnv{out: new(bytes.Buffer)}
	env.u = &tinyUpdater{
		base:    srv.URL + "/rel",
		target:  "linux_test",
		current: current,
		exe:     exe,
		out:     env.out,
		confirm: func(string) bool { return true },
		// The test "executables" are data; report the version embedded in them.
		verify: func(path string) (string, error) {
			b, err := os.ReadFile(path)
			if err != nil {
				return "", err
			}
			v, _, _ := strings.Cut(strings.TrimPrefix(string(b), "UPX! "), " ")
			return v, nil
		},
		restart: func() error { env.restarted = true; return nil },
	}
	return env
}

func (e *tinyTestEnv) installed(t *testing.T) string {
	b, err := os.ReadFile(e.u.exe)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func (e *tinyTestEnv) leftovers(t *testing.T) []string {
	m, _ := filepath.Glob(filepath.Join(filepath.Dir(e.u.exe), ".tailscaled.tiny-update.*"))
	return m
}

var (
	tinyRel1 = tinyTestRelease{version: "1.104.4", plain: []byte("1.104.4 plain"), upx: []byte("UPX! 1.104.4 packed")}
	tinyRel2 = tinyTestRelease{version: "1.106.0", plain: []byte("1.106.0 plain"), upx: []byte("UPX! 1.106.0 packed")}
)

func TestTinyUpdateInstallsNewerPlain(t *testing.T) {
	srv := newTinyTestServer(t, "1.106.0", tinyRel1, tinyRel2)
	e := newTinyTestEnv(t, srv, "1.104.4", tinyRel1.plain)
	if err := e.u.run("", false); err != nil {
		t.Fatalf("run: %v\n%s", err, e.out)
	}
	if got := e.installed(t); got != string(tinyRel2.plain) {
		t.Errorf("installed %q, want the uncompressed 1.106.0", got)
	}
	if b, err := os.ReadFile(e.u.exe + ".old"); err != nil || string(b) != string(tinyRel1.plain) {
		t.Errorf("backup = %q, %v; want previous executable", b, err)
	}
	if !e.restarted {
		t.Error("service not restarted")
	}
	if l := e.leftovers(t); len(l) != 0 {
		t.Errorf("temporary files left: %v", l)
	}
	// Pinned download: the binary comes from v1.106.0, not permalink/latest.
	if want := "/rel/permalink/latest/downloads/linux_test.manifest /rel/v1.106.0/downloads/linux_test"; srv.paths() != want {
		t.Errorf("requests = %q, want %q", srv.paths(), want)
	}
}

func TestTinyUpdateKeepsUPXVariant(t *testing.T) {
	srv := newTinyTestServer(t, "1.106.0", tinyRel1, tinyRel2)
	e := newTinyTestEnv(t, srv, "1.104.4", tinyRel1.upx)
	if err := e.u.run("", false); err != nil {
		t.Fatalf("run: %v\n%s", err, e.out)
	}
	if got := e.installed(t); got != string(tinyRel2.upx) {
		t.Errorf("installed %q, want the UPX 1.106.0", got)
	}
}

func TestTinyUpdateUpToDate(t *testing.T) {
	srv := newTinyTestServer(t, "1.104.4", tinyRel1)
	for _, current := range []string{"1.104.4", "1.106.0"} {
		e := newTinyTestEnv(t, srv, current, []byte(current))
		if err := e.u.run("", false); err != nil {
			t.Fatalf("run: %v", err)
		}
		if e.installed(t) != current || e.restarted {
			t.Errorf("current %s: executable changed or service restarted", current)
		}
		if !strings.Contains(e.out.String(), "Already running") {
			t.Errorf("current %s: output %q", current, e.out)
		}
	}
	if strings.Contains(srv.paths(), "/downloads/linux_test ") || strings.HasSuffix(srv.paths(), "/downloads/linux_test") {
		t.Errorf("downloaded a binary while up to date: %s", srv.paths())
	}
}

func TestTinyUpdateExplicitVersion(t *testing.T) {
	srv := newTinyTestServer(t, "1.106.0", tinyRel1, tinyRel2)
	e := newTinyTestEnv(t, srv, "1.104.4", tinyRel1.plain)
	// Reinstalling the running version is allowed when asked for explicitly.
	if err := e.u.run("1.104.4", false); err != nil {
		t.Fatalf("run: %v\n%s", err, e.out)
	}
	if want := "/rel/v1.104.4/downloads/linux_test.manifest /rel/v1.104.4/downloads/linux_test"; srv.paths() != want {
		t.Errorf("requests = %q, want %q", srv.paths(), want)
	}
	if err := e.u.run("1.104", false); err == nil {
		t.Error("accepted malformed --version")
	}
}

func TestTinyUpdateDryRun(t *testing.T) {
	srv := newTinyTestServer(t, "1.106.0", tinyRel1, tinyRel2)
	e := newTinyTestEnv(t, srv, "1.104.4", tinyRel1.plain)
	if err := e.u.run("", true); err != nil {
		t.Fatal(err)
	}
	if e.installed(t) != string(tinyRel1.plain) || e.restarted {
		t.Error("dry run changed something")
	}
	if !strings.Contains(e.out.String(), "Would install") {
		t.Errorf("output %q", e.out)
	}
}

func TestTinyUpdateRejectsBadDownloads(t *testing.T) {
	cases := []struct {
		name    string
		mutate  func(s *tinyTestServer)
		verify  func(string) (string, error)
		wantErr string
	}{
		{"sha mismatch", func(s *tinyTestServer) { s.override["/rel/v1.106.0/downloads/linux_test"] = "1.106.0 plaiN" }, nil, "SHA-256 mismatch"},
		{"size mismatch", func(s *tinyTestServer) { s.override["/rel/v1.106.0/downloads/linux_test"] = "1.106.0 plain!" }, nil, "manifest says"},
		{"wrong version inside", nil, func(string) (string, error) { return "1.104.4", nil }, "reports version"},
		{"does not run", nil, func(string) (string, error) { return "", errors.New("exec format error") }, "does not run"},
		{"login page", func(s *tinyTestServer) {
			s.override["/rel/permalink/latest/downloads/linux_test.manifest"] = "<html>sign in</html>"
		}, nil, "not a Tinyscale manifest"},
		{"future format", func(s *tinyTestServer) {
			s.override["/rel/permalink/latest/downloads/linux_test.manifest"] = "FORMAT=2\nVERSION=9.0.0\n"
		}, nil, "unsupported manifest FORMAT=2"},
		{"other target", func(s *tinyTestServer) {
			s.override["/rel/permalink/latest/downloads/linux_test.manifest"] = tinyRel2.manifest("linux_other")
		}, nil, "is for target"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := newTinyTestServer(t, "1.106.0", tinyRel1, tinyRel2)
			if tc.mutate != nil {
				tc.mutate(srv)
			}
			e := newTinyTestEnv(t, srv, "1.104.4", tinyRel1.plain)
			if tc.verify != nil {
				e.u.verify = tc.verify
			}
			err := e.u.run("", false)
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("err = %v, want %q", err, tc.wantErr)
			}
			if e.installed(t) != string(tinyRel1.plain) || e.restarted {
				t.Error("executable replaced or service restarted after a failed update")
			}
			if l := e.leftovers(t); len(l) != 0 {
				t.Errorf("temporary files left: %v", l)
			}
		})
	}
}

func TestTinyUpdateSignInRedirect(t *testing.T) {
	srv := newTinyTestServer(t, "1.106.0", tinyRel2)
	login := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/users/sign_in" {
			fmt.Fprint(w, "<html>")
			return
		}
		http.Redirect(w, r, "/users/sign_in", http.StatusFound)
	}))
	defer login.Close()
	e := newTinyTestEnv(t, srv, "1.104.4", tinyRel1.plain)
	e.u.base = login.URL + "/rel"
	if err := e.u.run("", false); err == nil || !strings.Contains(err.Error(), "requires signing in") {
		t.Fatalf("err = %v, want a sign-in hint", err)
	}
}

func TestTinyUpdateTokenNotSentToOtherHosts(t *testing.T) {
	storage := newTinyTestServer(t, "1.106.0", tinyRel1, tinyRel2)
	gitlab := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("PRIVATE-TOKEN") != "secret" {
			http.Error(w, "no token", http.StatusUnauthorized)
			return
		}
		// Like GitLab: Release links redirect to (object) storage.
		http.Redirect(w, r, storage.URL+r.URL.Path, http.StatusFound)
	}))
	defer gitlab.Close()
	e := newTinyTestEnv(t, storage, "1.104.4", tinyRel1.plain)
	e.u.base = gitlab.URL + "/rel"
	e.u.token = "secret"
	if err := e.u.run("", false); err != nil {
		t.Fatalf("run: %v\n%s", err, e.out)
	}
	if strings.Contains(storage.paths(), "+token") {
		t.Errorf("token leaked to redirect target: %s", storage.paths())
	}
}

func TestTinyUpdateConfig(t *testing.T) {
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	tok := filepath.Join(t.TempDir(), "token")
	os.WriteFile(tok, []byte("glpat-x\n"), 0o600)

	base, token, err := tinyUpdateConfig(env(map[string]string{"TT_UPDATE_URL": "https://h/p/-/releases/", "TT_UPDATE_TOKEN_FILE": tok}))
	if err != nil || base != "https://h/p/-/releases" || token != "glpat-x" {
		t.Errorf("got %q %q %v", base, token, err)
	}
	if _, _, err := tinyUpdateConfig(env(map[string]string{"TT_UPDATE_URL": "http://h/p"})); err == nil {
		t.Error("accepted plain http")
	}
	if _, _, err := tinyUpdateConfig(env(map[string]string{"TT_UPDATE_URL": "http://h/p", "TT_UPDATE_ALLOW_HTTP": "1"})); err != nil {
		t.Errorf("http with TT_UPDATE_ALLOW_HTTP=1: %v", err)
	}
	if _, _, err := tinyUpdateConfig(env(map[string]string{"TT_UPDATE_URL": "https://h/p", "TT_UPDATE_TOKEN_FILE": "/nonexistent"})); err == nil {
		t.Error("ignored a missing token file")
	}
	if got := tinyUpdateCmd.Name; got != "update" || maybeUpdateCmd() != tinyUpdateCmd {
		t.Error("tailscale update is not the Tinyscale command")
	}
}

func TestTinyUpdateSyslog(t *testing.T) {
	srv := newTinyTestServer(t, "1.106.0", tinyRel1, tinyRel2)

	e := newTinyTestEnv(t, srv, "1.104.4", tinyRel1.plain)
	var logged []string
	e.u.syslog = func(msg string) { logged = append(logged, msg) }
	if err := e.u.run("", false); err != nil {
		t.Fatalf("run: %v\n%s", err, e.out)
	}
	if got, want := strings.Join(logged, "\n"), strings.TrimSpace(e.out.String()); got != want {
		t.Errorf("system log = %q, want the same lines as stdout %q", got, want)
	}
	if n := len(logged); n == 0 || logged[n-1] != "Restarted tailscaled." {
		t.Errorf("system log = %q, want it to end with the restart", logged)
	}

	srv.override["/rel/v1.106.0/downloads/linux_test"] = "1.106.0 plaiN"
	e = newTinyTestEnv(t, srv, "1.104.4", tinyRel1.plain)
	logged = nil
	e.u.syslog = func(msg string) { logged = append(logged, msg) }
	if err := e.u.run("", false); err == nil {
		t.Fatal("run succeeded with a corrupt download")
	}
	if n := len(logged); n == 0 || !strings.HasPrefix(logged[n-1], "Update failed: ") || !strings.Contains(logged[n-1], "SHA-256 mismatch") {
		t.Errorf("system log = %q, want it to end with the failure", logged)
	}
}

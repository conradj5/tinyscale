"""Tiny in-memory GitLab Generic Package Registry + Releases API mock.

Usage: python3 -I mock_registry.py PORT_FILE LOG_FILE [--no-duplicates] [--fail-on NAME]

Serves PUT/GET on /api/v4/projects/<id>/packages/generic/<pkg>/<ver>/<file>,
requires a JOB-TOKEN header, records requests to LOG_FILE, and writes the
chosen port to PORT_FILE. GET of /__redirect__/<path> serves the object
without auth, emulating object-storage redirects when --redirect is given.

Also implements the subset of the Releases and Release links APIs used by
scripts/release.sh, the public /<ns>/<proj>/-/releases/permalink/latest/
downloads/<filepath> redirect, and an unauthenticated GET /__releases__
dump for test assertions.
"""
import http.server
import itertools
import json
import re
import sys
import threading
import urllib.parse

store = {}
lock = threading.Lock()
args = sys.argv[1:]
port_file, log_file = args[0], args[1]
no_dups = "--no-duplicates" in args
fail_on = args[args.index("--fail-on") + 1] if "--fail-on" in args else None
redirect = "--redirect" in args
PATH_RE = re.compile(r"^/api/v4/projects/(\d+)/packages/generic/([^/]+)/([^/]+)/([^/]+)$")
REL_RE = re.compile(r"^/api/v4/projects/\d+/releases(?:/([^/]+)(?:/assets/links(?:/(\d+))?)?)?$")
PERMALINK = "/-/releases/permalink/latest/downloads"
releases = {}  # tag -> release dict
tags = {}      # tag -> ref
clock = itertools.count(1)
link_ids = itertools.count(1)


def _add_link(rel, link):
    for other in rel["links"]:
        if other["name"] == link["name"] or other["url"] == link["url"]:
            return None
    obj = {"id": next(link_ids), "name": link["name"], "url": link["url"],
           "link_type": link.get("link_type", "other"), "filepath": link.get("filepath")}
    rel["links"].append(obj)
    return obj


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _log(self, code):
        with open(log_file, "a") as f:
            auth = "auth" if self.headers.get("JOB-TOKEN") == "secret-token" else "noauth"
            f.write(f"{self.command} {self.path} {code} {auth}\n")

    def _reply(self, code, body=b""):
        self._log(code)
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, obj):
        self._reply(code, json.dumps(obj).encode())

    def _body(self):
        n = int(self.headers.get("Content-Length", "0"))
        return self.rfile.read(n)

    def _releases(self, method):
        path = urllib.parse.urlsplit(self.path).path
        m = REL_RE.match(path)
        if not m:
            return self._reply(400)
        if self.headers.get("JOB-TOKEN") != "secret-token":
            return self._reply(401)
        tag, link_id = m.group(1), m.group(2)
        links_path = path.endswith("/assets/links") or link_id is not None
        with lock:
            if tag is None:
                if method == "GET":
                    out = sorted(releases.values(), key=lambda r: -r["released_at"])
                    return self._json(200, [{k: v for k, v in r.items() if k != "links"} for r in out])
                if method == "POST":
                    req = json.loads(self._body())
                    t = req["tag_name"]
                    if t in releases:
                        return self._json(409, {"message": "Release already exists"})
                    if t not in tags:
                        if not req.get("ref"):
                            return self._json(400, {"message": "Ref is not specified"})
                        tags[t] = req["ref"]
                    rel = {"tag_name": t, "name": req.get("name", t), "description": req.get("description", ""),
                           "released_at": next(clock), "links": []}
                    for link in req.get("assets", {}).get("links", []):
                        if _add_link(rel, link) is None:
                            return self._json(400, {"message": "duplicate link"})
                    releases[t] = rel
                    return self._json(201, rel)
                return self._reply(405)
            rel = releases.get(tag)
            if rel is None:
                return self._json(404, {"message": "404 Not Found"})
            if not links_path:
                if method == "GET":
                    return self._json(200, rel)
                if method == "PUT":
                    req = json.loads(self._body())
                    rel["description"] = req.get("description", rel["description"])
                    return self._json(200, rel)
                return self._reply(405)
            if method == "GET" and link_id is None:
                return self._json(200, rel["links"])
            if method == "POST" and link_id is None:
                obj = _add_link(rel, json.loads(self._body()))
                return self._json(201, obj) if obj else self._json(400, {"message": "duplicate link"})
            if method == "PUT" and link_id is not None:
                req = json.loads(self._body())
                for obj in rel["links"]:
                    if obj["id"] == int(link_id):
                        obj.update({k: req[k] for k in ("name", "url", "filepath", "link_type") if k in req})
                        return self._json(200, obj)
                return self._reply(404)
            return self._reply(405)

    def do_GET(self):
        if self.path == "/__releases__":
            with lock:
                return self._json(200, {"tags": tags, "releases": releases})
        if PERMALINK in self.path:
            filepath = self.path.split(PERMALINK, 1)[1]
            with lock:
                latest = max(releases.values(), key=lambda r: r["released_at"], default=None)
                target = next((l["url"] for l in (latest or {}).get("links", []) if l["filepath"] == filepath), None)
            if target is None:
                return self._reply(404)
            self._log(302)
            self.send_response(302)
            self.send_header("Location", target)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if "/releases" in self.path and self.path.startswith("/api/"):
            return self._releases("GET")
        if self.path.startswith("/__redirect__/"):
            key = self.path[len("/__redirect__"):]
            if self.headers.get("JOB-TOKEN"):
                return self._reply(400, b"token leaked to storage")
            with lock:
                data = store.get(key)
            return self._reply(200, data) if data is not None else self._reply(404)
        if self.headers.get("JOB-TOKEN") != "secret-token":
            return self._reply(401)
        if not PATH_RE.match(self.path):
            return self._reply(400)
        with lock:
            data = store.get(self.path)
        if data is None:
            return self._reply(404, b'{"message":"404 Not Found"}')
        if redirect:
            self._log(302)
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/__redirect__{self.path}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self._reply(200, data)

    def do_POST(self):
        return self._releases("POST")

    def do_PUT(self):
        if "/releases" in self.path:
            return self._releases("PUT")
        if self.headers.get("JOB-TOKEN") != "secret-token":
            return self._reply(401)
        if not PATH_RE.match(self.path):
            return self._reply(400)
        n = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(n)
        if fail_on and self.path.endswith("/" + fail_on):
            return self._reply(500, b"injected failure")
        with lock:
            if no_dups and self.path in store:
                return self._reply(403, b'{"message":"Duplicate package is not allowed"}')
            store[self.path] = data
        self._reply(201, b'{"message":"201 Created"}')


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(port_file, "w") as f:
    f.write(str(srv.server_port))
srv.serve_forever()

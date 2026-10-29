"""Unit tests for tools/platforms.py."""

import copy
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import platforms as p  # noqa: E402
import yaml  # noqa: E402

COMMIT = "27047635f237d1f3e0b08c0f487674757f30d2f7"

BASE = {
    "schema_version": 1,
    "defaults": {
        "enabled": False,
        "combined": False,
        "features": {"mode": "minimal", "add": ["cli", "osrouter"], "remove": []},
        "extra_tags": [],
        "strip": True,
        "cgo": False,
        "compression": {"enabled": False, "tool": "upx", "args": ["--best"]},
        "validation": {"format": "elf", "static": True, "smoke_test": "auto",
                       "max_size": None, "max_compressed_size": None},
    },
    "os_defaults": {
        "linux": {"combined": True, "compression": {"enabled": True}},
        "darwin": {"validation": {"format": "macho", "static": False}},
    },
    "platforms": [
        {"os": "linux", "arch": "arm64", "enabled": True,
         "validation": {"max_size": "40MiB", "max_compressed_size": 12000000}},
    ],
}


def cfg(**changes):
    data = copy.deepcopy(BASE)
    for key, val in changes.items():
        data[key] = val
    return data


class ResolveTests(unittest.TestCase):
    def test_repository_config_is_valid(self):
        targets = p.load_config(ROOT / "platforms.yml")
        ids = [t["id"] for t in targets]
        self.assertIn("linux_arm64", ids)
        self.assertEqual(len(ids), len(set(ids)))
        arm64 = p.find_target(targets, "linux_arm64")
        self.assertTrue(arm64["enabled"])
        self.assertTrue(arm64["combined"])
        self.assertIn("cli", arm64["features"]["add"])
        self.assertEqual(arm64["validation"]["qemu"], "qemu-aarch64")

    def test_layering(self):
        t = p.resolve_config(cfg())[0]
        self.assertEqual(t["id"], "linux_arm64")
        self.assertTrue(t["combined"])                  # from os_defaults
        self.assertTrue(t["compression"]["enabled"])    # from os_defaults
        self.assertEqual(t["compression"]["args"], ["--best"])  # from defaults
        self.assertEqual(t["validation"]["max_size"], 40 * 1024 * 1024)
        self.assertEqual(t["validation"]["max_compressed_size"], 12000000)
        self.assertEqual(t["go_env"], {"GOOS": "linux", "GOARCH": "arm64"})
        self.assertEqual(t["validation"]["smoke_test"], "qemu")

    def test_variant_naming(self):
        data = cfg(platforms=[
            {"os": "linux", "arch": "arm", "goarm": "7", "enabled": True},
            {"os": "linux", "arch": "arm", "goarm": 6, "enabled": True},
            {"os": "linux", "arch": "amd64", "goamd64": "v3"},
            {"os": "linux", "arch": "mipsle", "gomips": "softfloat"},
        ])
        targets = p.resolve_config(data)
        self.assertEqual([t["id"] for t in targets],
                         ["linux_arm_v7", "linux_arm_v6", "linux_amd64_v3", "linux_mipsle_softfloat"])
        self.assertEqual(targets[0]["go_env"]["GOARM"], "7")
        self.assertEqual(targets[1]["go_env"]["GOARM"], "6")
        self.assertEqual(p.artifact_base("1.104.4", targets[0]), "tailscale-tiny_1.104.4_linux_arm_v7")

    def test_variant_wrong_arch_rejected(self):
        with self.assertRaisesRegex(p.ConfigError, "only valid for GOARCH"):
            p.resolve_config(cfg(platforms=[{"os": "linux", "arch": "arm64", "goarm": "7"}]))

    def test_invalid_variant_value(self):
        with self.assertRaisesRegex(p.ConfigError, "invalid value"):
            p.resolve_config(cfg(platforms=[{"os": "linux", "arch": "arm", "goarm": "8"}]))

    def test_duplicate_target(self):
        with self.assertRaisesRegex(p.ConfigError, "duplicate"):
            p.resolve_config(cfg(platforms=[{"os": "linux", "arch": "arm64"},
                                            {"os": "linux", "arch": "arm64"}]))

    def test_unknown_keys(self):
        with self.assertRaisesRegex(p.ConfigError, "unknown key"):
            p.resolve_config(cfg(platforms=[{"os": "linux", "arch": "arm64", "colour": "red"}]))
        with self.assertRaisesRegex(p.ConfigError, "unknown key"):
            p.resolve_config(cfg(platforms=[{"os": "linux", "arch": "arm64",
                                             "validation": {"max_sise": 1}}]))

    def test_bad_names(self):
        for bad in ("Linux", "linux/arm64", "", None):
            with self.assertRaises(p.ConfigError):
                p.resolve_config(cfg(platforms=[{"os": bad, "arch": "arm64"}]))

    def test_non_combined_drops_cli(self):
        t = p.resolve_config(cfg(platforms=[{"os": "freebsd", "arch": "amd64"}]))[0]
        self.assertFalse(t["combined"])
        self.assertNotIn("cli", t["features"]["add"])
        self.assertEqual(t["validation"]["smoke_test"], "none")

    def test_combined_requires_cli(self):
        with self.assertRaisesRegex(p.ConfigError, "requires 'cli'"):
            p.resolve_config(cfg(platforms=[{"os": "linux", "arch": "arm64",
                                             "features": {"add": ["osrouter"]}}]))

    def test_full_mode(self):
        t = p.resolve_config(cfg(platforms=[{"os": "linux", "arch": "arm64",
                                             "features": {"mode": "full", "add": [],
                                                          "remove": ["ssh"]}}]))[0]
        self.assertEqual(t["features"], {"mode": "full", "add": [], "remove": ["ssh"]})
        with self.assertRaisesRegex(p.ConfigError, "not used with mode: full"):
            p.resolve_config(cfg(platforms=[{"os": "linux", "arch": "arm64",
                                             "features": {"mode": "full"}}]))

    def test_add_remove_overlap(self):
        with self.assertRaisesRegex(p.ConfigError, "in both add and remove"):
            p.resolve_config(cfg(platforms=[{"os": "linux", "arch": "arm64",
                                             "features": {"remove": ["osrouter"]}}]))

    def test_upx_unsupported(self):
        with self.assertRaisesRegex(p.ConfigError, "UPX is not supported"):
            p.resolve_config(cfg(platforms=[{"os": "darwin", "arch": "arm64",
                                             "compression": {"enabled": True}}]))
        with self.assertRaisesRegex(p.ConfigError, "UPX does not support"):
            p.resolve_config(cfg(platforms=[{"os": "linux", "arch": "riscv64"}]))

    def test_qemu_only_for_linux(self):
        with self.assertRaisesRegex(p.ConfigError, "qemu"):
            p.resolve_config(cfg(platforms=[{"os": "freebsd", "arch": "amd64",
                                             "validation": {"smoke_test": "qemu"}}]))

    def test_windows_suffix(self):
        t = p.resolve_config(cfg(platforms=[{"os": "windows", "arch": "amd64",
                                             "validation": {"format": "pe", "smoke_test": "none"}}]))[0]
        self.assertEqual(t["executable_suffix"], ".exe")

    def test_sizes(self):
        self.assertEqual(p.parse_size("12MiB", "x"), 12 * 1024 * 1024)
        self.assertEqual(p.parse_size("1.5 MB", "x"), 1500000)
        self.assertEqual(p.parse_size(100, "x"), 100)
        self.assertIsNone(p.parse_size(None, "x"))
        for bad in ("12 parsecs", -1, 0, True, "0MiB"):
            with self.assertRaises(p.ConfigError):
                p.parse_size(bad, "x")

    def test_schema_version(self):
        with self.assertRaisesRegex(p.ConfigError, "schema_version"):
            p.resolve_config(cfg(schema_version=2))


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.targets = p.resolve_config(cfg(platforms=[
            {"os": "linux", "arch": "arm64", "enabled": True},
            {"os": "linux", "arch": "amd64", "enabled": True},
            {"os": "linux", "arch": "riscv64", "enabled": False,
             "compression": {"enabled": False}},
        ]))

    def gen(self, ids, publish=True):
        return p.generate_pipeline(self.targets, ids, version="1.104.4", commit=COMMIT,
                                   go_image="golang:1.27.3-alpine3.24", publish=publish)

    def test_jobs_per_target(self):
        doc = self.gen(["linux_arm64", "linux_amd64"])
        self.assertIn("build:linux_arm64", doc)
        self.assertIn("publish:linux_amd64", doc)
        pub = doc["publish:linux_arm64"]
        # Each publish job depends only on its own build job.
        self.assertEqual(pub["needs"], [{"job": "build:linux_arm64", "artifacts": True}])
        cfg_json = json.loads(doc["build:linux_arm64"]["variables"]["TT_TARGET_CONFIG"])
        self.assertEqual(cfg_json["id"], "linux_arm64")
        self.assertEqual(doc["build:linux_arm64"]["image"], "golang:1.27.3-alpine3.24")
        # bash is installed by plain sh before any bash script runs.
        self.assertEqual(doc["build:linux_arm64"]["script"][0],
                         "sh scripts/ci/install-deps.sh build qemu-aarch64")
        self.assertEqual(pub["script"][0], "sh scripts/ci/install-deps.sh publish")
        self.assertEqual(pub["image"], "alpine:3.24")

    def test_helper_image(self):
        doc = p.generate_pipeline(self.targets, ["linux_arm64"], version="1.104.4", commit=COMMIT,
                                  go_image="proxy.example/g/golang:1.27.3-alpine3.24", publish=True,
                                  helper_image="proxy.example/g/alpine:3.24")
        self.assertEqual(doc["publish:linux_arm64"]["image"], "proxy.example/g/alpine:3.24")
        self.assertEqual(doc["release"]["image"], "proxy.example/g/alpine:3.24")
        self.assertEqual(doc["build:linux_arm64"]["image"], "proxy.example/g/golang:1.27.3-alpine3.24")
        with self.assertRaises(p.ConfigError):
            p.generate_pipeline(self.targets, [], version="1.104.4", commit=COMMIT,
                                go_image="golang:1", publish=True, helper_image="alpine 3")

    def test_no_publish(self):
        doc = self.gen(["linux_arm64"], publish=False)
        self.assertNotIn("publish:linux_arm64", doc)
        self.assertNotIn("release", doc)

    def test_release_job(self):
        doc = self.gen(["linux_arm64"])
        rel = doc["release"]
        self.assertEqual(rel["stage"], "release")
        self.assertEqual(rel["needs"], [{"job": "publish:linux_arm64", "artifacts": False}])
        # The Release covers every enabled target, not just this run's builds.
        self.assertEqual(rel["variables"]["TT_RELEASE_TARGETS"], "linux_arm64,linux_amd64")

    def test_empty_plan(self):
        doc = self.gen([])
        # Release job still runs so an already-published version gets its Release.
        self.assertEqual(doc["release"]["needs"], [])
        self.assertNotIn("nothing-to-build", doc)
        doc = self.gen([], publish=False)
        self.assertIn("nothing-to-build", doc)

    def test_disabled_target_rejected(self):
        with self.assertRaisesRegex(p.ConfigError, "not enabled"):
            self.gen(["linux_riscv64"])

    def test_input_validation(self):
        with self.assertRaises(p.ConfigError):
            p.generate_pipeline(self.targets, [], version="1.104.4-pre", commit=COMMIT,
                                go_image="golang:1.27.3-alpine3.24", publish=True)
        with self.assertRaises(p.ConfigError):
            p.generate_pipeline(self.targets, [], version="1.104.4", commit="abc",
                                go_image="golang:1.27.3-alpine3.24", publish=True)
        with self.assertRaises(p.ConfigError):
            p.generate_pipeline(self.targets, [], version="1.104.4", commit=COMMIT,
                                go_image="golang; rm -rf /", publish=True)

    def test_cli_output_is_plain_yaml(self):
        import io
        import contextlib
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "child.yml"
            rc = p.main(["--config", str(ROOT / "platforms.yml"), "pipeline",
                         "--version", "1.104.4", "--commit", COMMIT,
                         "--go-image", "golang:1.27.3-alpine3.24",
                         "--targets", "linux_arm64,linux_amd64", "-o", str(out)])
            self.assertEqual(rc, 0)
            text = out.read_text()
            self.assertNotIn("&id", text)  # no YAML anchors
            doc = yaml.safe_load(text)
            self.assertEqual(doc["build:linux_amd64"]["variables"]["TT_BUILD_VERSION"], "1.104.4")
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            rc = p.main(["--config", str(ROOT / "platforms.yml"), "show", "nope_nope"])
        self.assertEqual(rc, 1)
        self.assertIn("unknown target", buf.getvalue())


if __name__ == "__main__":
    unittest.main()

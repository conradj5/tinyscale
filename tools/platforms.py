#!/usr/bin/env python3
"""Load, validate and resolve Tailscale Tiny build targets from platforms.yml.

Subcommands:
  validate                    validate the configuration
  list [--all] [--json]       list target ids (enabled only unless --all)
  show TARGET_ID              print one resolved target as JSON
  pipeline ...                generate the GitLab child pipeline

Requires Python 3.9+ and PyYAML.
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover - environment problem
    sys.exit("platforms.py: PyYAML is required (apk add py3-yaml / pip install pyyaml)")

SCHEMA_VERSION = 1
PROJECT = "tailscale-tiny"

TOP_LEVEL_KEYS = {"schema_version", "defaults", "os_defaults", "platforms"}
TARGET_KEYS = {
    "os", "arch", "enabled", "combined", "features", "extra_tags", "strip",
    "cgo", "compression", "validation", "notes",
    # architecture variant settings
    "goarm", "goamd64", "go386", "gomips", "gomips64", "goarm64",
    "goriscv64", "goppc64",
}
FEATURE_KEYS = {"mode", "add", "remove"}
COMPRESSION_KEYS = {"enabled", "tool", "args"}
VALIDATION_KEYS = {
    "format", "static", "smoke_test", "max_size", "max_compressed_size",
}

# Architecture variant knobs: config key -> (applicable GOARCH values,
# Go environment variable, allowed values).
VARIANTS = {
    "goarm": ({"arm"}, "GOARM", re.compile(r"^[567](,(softfloat|hardfloat))?$")),
    "goamd64": ({"amd64"}, "GOAMD64", re.compile(r"^v[1-4]$")),
    "go386": ({"386"}, "GO386", re.compile(r"^(sse2|softfloat)$")),
    "gomips": ({"mips", "mipsle"}, "GOMIPS", re.compile(r"^(hardfloat|softfloat)$")),
    "gomips64": ({"mips64", "mips64le"}, "GOMIPS64", re.compile(r"^(hardfloat|softfloat)$")),
    "goarm64": ({"arm64"}, "GOARM64", re.compile(r"^v[89]\.[0-9](,(lse|crypto))*$")),
    "goriscv64": ({"riscv64"}, "GORISCV64", re.compile(r"^rva2[0-9]u64$")),
    "goppc64": ({"ppc64", "ppc64le"}, "GOPPC64", re.compile(r"^power(8|9|10)$")),
}

FORMATS = {"elf", "macho", "pe"}
SMOKE_TESTS = {"auto", "qemu", "native", "none"}
FEATURE_MODES = {"minimal", "full"}
COMPRESSION_TOOLS = {"upx"}

# GOARCH -> qemu user-mode emulator binary (Alpine/Debian naming).
QEMU_BINARIES = {
    "amd64": "qemu-x86_64",
    "386": "qemu-i386",
    "arm64": "qemu-aarch64",
    "arm": "qemu-arm",
    "riscv64": "qemu-riscv64",
    "mips": "qemu-mips",
    "mipsle": "qemu-mipsel",
    "mips64": "qemu-mips64",
    "mips64le": "qemu-mips64el",
    "ppc64le": "qemu-ppc64le",
    "ppc64": "qemu-ppc64",
    "s390x": "qemu-s390x",
    "loong64": "qemu-loongarch64",
}

# GOARCH values UPX can compress for ELF executables (UPX 4.x).
UPX_ELF_ARCHES = {"amd64", "386", "arm64", "arm", "mips", "mipsle", "ppc64le"}

NAME_RE = re.compile(r"^[a-z0-9]+$")
SIZE_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*([KMG]i?B|B)?\s*$", re.IGNORECASE)
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
FEATURE_RE = re.compile(r"^[a-z0-9_]+$")
TAG_RE = re.compile(r"^[A-Za-z0-9_.]+$")
SIZE_UNITS = {
    "b": 1, "kb": 1000, "mb": 1000**2, "gb": 1000**3,
    "kib": 1024, "mib": 1024**2, "gib": 1024**3,
}


class ConfigError(Exception):
    pass


class _NoAliasDumper(yaml.SafeDumper):
    """Emit repeated values in full instead of YAML anchors/aliases."""

    def ignore_aliases(self, data: Any) -> bool:
        return True


def parse_size(value: Any, where: str) -> int | None:
    """Convert an int or a size string such as '12MiB' to bytes."""
    if value is None:
        return None
    if isinstance(value, bool):
        raise ConfigError(f"{where}: invalid size {value!r}")
    if isinstance(value, int):
        if value <= 0:
            raise ConfigError(f"{where}: size must be positive")
        return value
    if isinstance(value, str):
        m = SIZE_RE.match(value)
        if m:
            unit = (m.group(2) or "B").lower()
            n = int(float(m.group(1)) * SIZE_UNITS[unit])
            if n <= 0:
                raise ConfigError(f"{where}: size must be positive")
            return n
    raise ConfigError(f"{where}: invalid size {value!r}")


def deep_merge(base: dict, override: dict) -> dict:
    """Recursively merge override into a copy of base. Lists are replaced."""
    out = copy.deepcopy(base)
    for key, val in override.items():
        if isinstance(val, dict) and isinstance(out.get(key), dict):
            out[key] = deep_merge(out[key], val)
        else:
            out[key] = copy.deepcopy(val)
    return out


def _check_keys(obj: Any, allowed: set, where: str) -> None:
    if not isinstance(obj, dict):
        raise ConfigError(f"{where}: expected a mapping")
    unknown = set(obj) - allowed
    if unknown:
        raise ConfigError(f"{where}: unknown key(s): {', '.join(sorted(unknown))}")


def _check_partial(obj: dict, where: str) -> None:
    """Check key names in a defaults layer or target entry."""
    _check_keys(obj, TARGET_KEYS, where)
    for key, allowed in (("features", FEATURE_KEYS),
                         ("compression", COMPRESSION_KEYS),
                         ("validation", VALIDATION_KEYS)):
        if key in obj:
            _check_keys(obj[key], allowed, f"{where}.{key}")


def _bool(t: dict, key: str, where: str) -> bool:
    val = t.get(key)
    if not isinstance(val, bool):
        raise ConfigError(f"{where}.{key}: expected true or false, got {val!r}")
    return val


def _str_list(val: Any, where: str, pattern: re.Pattern) -> list[str]:
    if val is None:
        return []
    if not isinstance(val, list) or not all(isinstance(v, str) for v in val):
        raise ConfigError(f"{where}: expected a list of strings")
    for v in val:
        if not pattern.match(v):
            raise ConfigError(f"{where}: invalid entry {v!r}")
    return list(val)


def resolve_target(raw: dict, defaults: dict, os_defaults: dict, index: int) -> dict:
    where = f"platforms[{index}]"
    _check_partial(raw, where)
    goos, goarch = raw.get("os"), raw.get("arch")
    for key, val in (("os", goos), ("arch", goarch)):
        if not isinstance(val, str) or not NAME_RE.match(val):
            raise ConfigError(f"{where}.{key}: expected a lowercase GOOS/GOARCH name, got {val!r}")
    where = f"platforms[{index}] ({goos}/{goarch})"

    merged = deep_merge(defaults, os_defaults.get(goos, {}))
    merged = deep_merge(merged, raw)

    go_env = {"GOOS": goos, "GOARCH": goarch}
    variant = None
    for key, (arches, env, pattern) in VARIANTS.items():
        if key not in merged:
            continue
        val = merged[key]
        if isinstance(val, int) and not isinstance(val, bool):
            val = str(val)
        if not isinstance(val, str) or not pattern.match(val):
            raise ConfigError(f"{where}.{key}: invalid value {merged[key]!r}")
        if goarch not in arches:
            raise ConfigError(f"{where}.{key}: only valid for GOARCH {', '.join(sorted(arches))}")
        if variant is not None:
            raise ConfigError(f"{where}: more than one architecture variant set")
        go_env[env] = val
        variant = val

    enabled = _bool(merged, "enabled", where)
    combined = _bool(merged, "combined", where)
    strip = _bool(merged, "strip", where)
    cgo = _bool(merged, "cgo", where)

    features = merged.get("features") or {}
    mode = features.get("mode", "minimal")
    if mode not in FEATURE_MODES:
        raise ConfigError(f"{where}.features.mode: must be one of {sorted(FEATURE_MODES)}")
    add = _str_list(features.get("add"), f"{where}.features.add", FEATURE_RE)
    remove = _str_list(features.get("remove"), f"{where}.features.remove", FEATURE_RE)
    if mode == "full" and add:
        raise ConfigError(f"{where}.features.add: not used with mode: full (everything is included)")
    if not combined:
        # The CLI is built as a separate executable; don't embed it.
        add = [f for f in add if f != "cli"]
    elif mode == "minimal" and "cli" not in add:
        raise ConfigError(f"{where}: combined: true requires 'cli' in features.add")
    if combined and "cli" in remove:
        raise ConfigError(f"{where}: combined: true conflicts with removing 'cli'")
    overlap = set(add) & set(remove)
    if overlap:
        raise ConfigError(f"{where}.features: in both add and remove: {', '.join(sorted(overlap))}")
    extra_tags = _str_list(merged.get("extra_tags"), f"{where}.extra_tags", TAG_RE)

    validation = merged.get("validation") or {}
    fmt = validation.get("format", "elf")
    if fmt not in FORMATS:
        raise ConfigError(f"{where}.validation.format: must be one of {sorted(FORMATS)}")
    smoke = validation.get("smoke_test", "auto")
    if smoke not in SMOKE_TESTS:
        raise ConfigError(f"{where}.validation.smoke_test: must be one of {sorted(SMOKE_TESTS)}")
    if smoke == "auto":
        smoke = "qemu" if goos == "linux" and goarch in QEMU_BINARIES else "none"
    if smoke == "qemu" and (goos != "linux" or goarch not in QEMU_BINARIES):
        raise ConfigError(f"{where}.validation.smoke_test: qemu user-mode emulation only supports linux targets")
    static = _bool(validation, "static", f"{where}.validation")

    compression = merged.get("compression") or {}
    comp_enabled = _bool(compression, "enabled", f"{where}.compression")
    tool = compression.get("tool", "upx")
    if tool not in COMPRESSION_TOOLS:
        raise ConfigError(f"{where}.compression.tool: must be one of {sorted(COMPRESSION_TOOLS)}")
    comp_args = _str_list(compression.get("args"), f"{where}.compression.args",
                          re.compile(r"^-[A-Za-z0-9=-]+$"))
    if comp_enabled and tool == "upx":
        if fmt != "elf" or goos not in {"linux", "freebsd", "netbsd", "openbsd"}:
            raise ConfigError(f"{where}.compression: UPX is not supported for {goos} {fmt} executables")
        if goarch not in UPX_ELF_ARCHES:
            raise ConfigError(f"{where}.compression: UPX does not support {goos}/{goarch}")

    target_id = f"{goos}_{goarch}"
    if variant is not None:
        suffix = re.sub(r"[^a-z0-9]+", "_", variant.lower()).strip("_")
        if goarch == "arm" and suffix[0].isdigit():
            suffix = "v" + suffix
        target_id += f"_{suffix}"

    return {
        "id": target_id,
        "os": goos,
        "arch": goarch,
        "variant": variant,
        "enabled": enabled,
        "combined": combined,
        "go_env": go_env,
        "cgo": cgo,
        "strip": strip,
        "features": {"mode": mode, "add": add, "remove": remove},
        "extra_tags": extra_tags,
        "executable_suffix": ".exe" if goos == "windows" else "",
        "compression": {"enabled": comp_enabled, "tool": tool, "args": comp_args},
        "validation": {
            "format": fmt,
            "static": static,
            "smoke_test": smoke,
            "qemu": QEMU_BINARIES.get(goarch) if smoke == "qemu" else None,
            "max_size": parse_size(validation.get("max_size"), f"{where}.validation.max_size"),
            "max_compressed_size": parse_size(validation.get("max_compressed_size"),
                                              f"{where}.validation.max_compressed_size"),
        },
    }


def load_config(path: str | Path) -> list[dict]:
    try:
        with open(path, encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except OSError as e:
        raise ConfigError(f"cannot read {path}: {e}") from e
    except yaml.YAMLError as e:
        raise ConfigError(f"invalid YAML in {path}: {e}") from e
    return resolve_config(data)


def resolve_config(data: Any) -> list[dict]:
    _check_keys(data, TOP_LEVEL_KEYS, "platforms.yml")
    if data.get("schema_version") != SCHEMA_VERSION:
        raise ConfigError(f"schema_version must be {SCHEMA_VERSION}")
    defaults = data.get("defaults") or {}
    _check_partial(defaults, "defaults")
    os_defaults = data.get("os_defaults") or {}
    if not isinstance(os_defaults, dict):
        raise ConfigError("os_defaults: expected a mapping")
    for goos, layer in os_defaults.items():
        _check_partial(layer, f"os_defaults.{goos}")
        if "os" in layer or "arch" in layer:
            raise ConfigError(f"os_defaults.{goos}: may not set os or arch")
    if "os" in defaults or "arch" in defaults:
        raise ConfigError("defaults: may not set os or arch")
    platforms = data.get("platforms")
    if not isinstance(platforms, list) or not platforms:
        raise ConfigError("platforms: expected a non-empty list")

    targets, seen = [], set()
    for i, raw in enumerate(platforms):
        t = resolve_target(raw, defaults, os_defaults, i)
        if t["id"] in seen:
            raise ConfigError(f"platforms[{i}]: duplicate target id {t['id']!r}")
        seen.add(t["id"])
        targets.append(t)
    return targets


def find_target(targets: list[dict], target_id: str) -> dict:
    for t in targets:
        if t["id"] == target_id:
            return t
    raise ConfigError(f"unknown target {target_id!r} (known: {', '.join(t['id'] for t in targets)})")


def artifact_base(version: str, target: dict) -> str:
    if not VERSION_RE.match(version):
        raise ConfigError(f"invalid version {version!r}")
    return f"{PROJECT}_{version}_{target['id']}"


IMAGE_RE = re.compile(r"^[A-Za-z0-9./:_@-]+$")


def generate_pipeline(targets: list[dict], build_ids: list[str], *, version: str,
                      commit: str, go_image: str, publish: bool,
                      helper_image: str = "alpine:3.24") -> dict:
    """Return the child pipeline configuration as a dict."""
    if not VERSION_RE.match(version):
        raise ConfigError(f"invalid version {version!r}")
    if not re.match(r"^[0-9a-f]{40}$", commit):
        raise ConfigError(f"invalid commit {commit!r}")
    for image in (go_image, helper_image):
        if not IMAGE_RE.match(image):
            raise ConfigError(f"invalid image {image!r}")

    common_vars = {
        "TT_BUILD_VERSION": version,
        "TT_BUILD_COMMIT": commit,
    }
    pipeline: dict[str, Any] = {
        "stages": ["build", "publish", "release"],
        "workflow": {"rules": [{"when": "always"}]},
        "default": {
            "interruptible": True,
            "retry": {"max": 1, "when": ["runner_system_failure",
                                         "stuck_or_timeout_failure",
                                         "scheduler_failure"]},
        },
    }

    if not build_ids and not publish:
        pipeline["nothing-to-build"] = {
            "stage": "build",
            "image": helper_image,
            "variables": common_vars,
            "script": [f'echo "All enabled targets for {version} are already published."'],
        }
        return pipeline

    for target_id in build_ids:
        t = find_target(targets, target_id)
        if not t["enabled"]:
            raise ConfigError(f"target {target_id!r} is not enabled")
        job_vars = dict(common_vars)
        job_vars["TT_TARGET_ID"] = target_id
        job_vars["TT_TARGET_CONFIG"] = json.dumps(t, sort_keys=True, separators=(",", ":"))
        pipeline[f"build:{target_id}"] = {
            "stage": "build",
            "image": go_image,
            "variables": job_vars,
            "cache": [
                # The module cache is content-addressed and verified against
                # go.sum, so one shared key is safe across versions.
                {"key": "gomod-v1", "paths": [".cache/go-mod"], "when": "on_success"},
                {"key": f"gobuild-{target_id}-v1", "paths": [".cache/go-build"],
                 "when": "on_success"},
            ],
            # Official golang/alpine images lack bash, so install tools with
            # plain sh before running the bash scripts.
            "script": [
                " ".join(["sh scripts/ci/install-deps.sh build",
                          t["validation"]["qemu"] or ""]).strip(),
                "scripts/ci/build-job.sh",
            ],
            "artifacts": {
                "name": f"{PROJECT}_{version}_{target_id}",
                "paths": [f"dist/{target_id}/"],
                "expire_in": "2 weeks",
                "when": "always",
            },
        }
        if publish:
            pipeline[f"publish:{target_id}"] = {
                "stage": "publish",
                "image": helper_image,
                "needs": [{"job": f"build:{target_id}", "artifacts": True}],
                "variables": dict(job_vars),
                "resource_group": f"publish-{target_id}",
                "interruptible": False,
                "script": [
                    "sh scripts/ci/install-deps.sh publish",
                    "scripts/ci/publish-job.sh",
                ],
            }

    if publish:
        # Runs after this pipeline's publish jobs (or immediately when every
        # target was already published) and creates or completes the GitLab
        # Release once all enabled targets are in the registry.
        enabled_ids = [t["id"] for t in targets if t["enabled"]]
        pipeline["release"] = {
            "stage": "release",
            "image": helper_image,
            "needs": [{"job": f"publish:{i}", "artifacts": False} for i in build_ids],
            "variables": dict(common_vars, TT_RELEASE_TARGETS=",".join(enabled_ids)),
            "resource_group": "release",
            "interruptible": False,
            "script": [
                "sh scripts/ci/install-deps.sh publish",
                "scripts/ci/release-job.sh",
            ],
        }
    return pipeline


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", default="platforms.yml")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("validate")
    p_list = sub.add_parser("list")
    p_list.add_argument("--all", action="store_true", help="include disabled targets")
    p_list.add_argument("--json", action="store_true")
    p_show = sub.add_parser("show")
    p_show.add_argument("target_id")
    p_name = sub.add_parser("artifact-base")
    p_name.add_argument("version")
    p_name.add_argument("target_id")
    p_pipe = sub.add_parser("pipeline")
    p_pipe.add_argument("--version", required=True)
    p_pipe.add_argument("--commit", required=True)
    p_pipe.add_argument("--go-image", required=True)
    p_pipe.add_argument("--helper-image", default="alpine:3.24",
                        help="image for publish/release jobs (default: alpine:3.24)")
    p_pipe.add_argument("--targets", default="",
                        help="comma-separated target ids to build (may be empty)")
    p_pipe.add_argument("--no-publish", action="store_true")
    p_pipe.add_argument("-o", "--output", default="-")
    args = parser.parse_args(argv)

    try:
        targets = load_config(args.config)
        if args.cmd == "validate":
            enabled = [t["id"] for t in targets if t["enabled"]]
            print(f"OK: {len(targets)} targets, {len(enabled)} enabled ({', '.join(enabled) or 'none'})")
        elif args.cmd == "list":
            sel = targets if args.all else [t for t in targets if t["enabled"]]
            if args.json:
                print(json.dumps(sel, indent=2, sort_keys=True))
            else:
                for t in sel:
                    print(t["id"])
        elif args.cmd == "show":
            print(json.dumps(find_target(targets, args.target_id), indent=2, sort_keys=True))
        elif args.cmd == "artifact-base":
            print(artifact_base(args.version, find_target(targets, args.target_id)))
        elif args.cmd == "pipeline":
            ids = [i for i in args.targets.split(",") if i]
            doc = generate_pipeline(targets, ids, version=args.version, commit=args.commit,
                                    go_image=args.go_image, publish=not args.no_publish,
                                    helper_image=args.helper_image)
            text = "# Generated by tools/platforms.py — do not edit.\n" + \
                yaml.dump(doc, Dumper=_NoAliasDumper, sort_keys=False, width=1000)
            if args.output == "-":
                sys.stdout.write(text)
            else:
                Path(args.output).write_text(text, encoding="utf-8")
    except ConfigError as e:
        print(f"platforms.py: error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

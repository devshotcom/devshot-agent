#!/usr/bin/env python3
"""
discover-lamp-variants.py — Spec 058 dynamic variant discovery.

Queries upstream APIs (WordPress, Packagist for Shopware + TYPO3) to
enumerate which (app, major.minor) variants of the LAMP matrix the
build pipeline should bake. Replaces the static wrapper-per-variant
pattern so new upstream majors land automatically.

Output:
  - JSON list to stdout, one entry per variant: {app, major_minor,
    resolved_version, variant_id, port, doc_root, max_body}.
  - <build_dir>/lamp-matrix.lock.json updated with the resolved set
    + denied entries + discovery timestamp, so a downstream replay
    or CI rerun gets the exact same matrix.

Fallback: if any upstream is unreachable, the lock file's previously
recorded variants are reused. Bake never silently produces an empty
matrix.

Usage:
  discover-lamp-variants.py <build-dir>
"""

import json
import re
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

# ── Deny-list ──────────────────────────────────────────────────────────────
# Variants we refuse to bake even when upstream offers them. Each entry
# is (app, major_minor). Spec 058 has the full justification per row.
DENY = {
    # Shopware 6.4 EOL Aug 2024; shopware/recovery composer.lock broken
    # post-EOL, post-install script fails. Needs custom install path.
    ("shopware", "6.4"),
    # TYPO3 v11 free support ended Oct 2024; `vendor/bin/typo3 setup`
    # is a v12+ CLI. v11 install needs LocalConfiguration.php + SQL
    # schema import, not modeled in _app_lib.sh.
    ("typo3", "11"),
}

# ── Tuneables ──────────────────────────────────────────────────────────────
# How far back to look for "actively maintained" majors. Anything whose
# latest patch landed before the cutoff is dropped. WP's API doesn't
# return per-version dates so its filter is slightly different (see
# discover_wordpress).
SUPPORT_WINDOW_DAYS = 730  # 24 months

# WordPress backports security to ~25 majors (4.7 → 6.9). 99 % of users
# only ever touch the last few. Cap at this many newest major.minor
# series so the matrix doesn't bloat to 5+ GB on disk for a long tail
# of legacy versions nobody installs. Override with WP_MAX_MAJORS env.
import os
WP_MAX_MAJORS = int(os.environ.get("WP_MAX_MAJORS", "5"))

HTTP_TIMEOUT_S = 15


class DiscoveryError(RuntimeError):
    """Expected network or upstream-payload failure eligible for lock fallback."""

APP_CONTRACTS = {
    "wordpress": {"prefix": "wp-", "port": 80, "doc_root": "/var/www/wordpress", "max_body": "64M", "major": re.compile(r"^\d+\.\d+$")},
    "shopware": {"prefix": "sw-", "port": 81, "doc_root": "/var/www/shopware/public", "max_body": "128M", "major": re.compile(r"^\d+\.\d+$")},
    "typo3": {"prefix": "t3-v", "port": 82, "doc_root": "/var/www/typo3/public", "max_body": "64M", "major": re.compile(r"^\d+$")},
}
VERSION_RE = re.compile(r"^\d+(?:\.\d+){1,3}$")
VARIANT_KEYS = {"app", "major_minor", "resolved_version", "variant_id", "port", "doc_root", "max_body"}


def validate_lock_data(data):
    """Reject any fallback lock that is not an exact safe discovery result."""
    if not isinstance(data, dict) or data.get("schema_version") != 1:
        raise ValueError("lock must be a schema_version 1 object")
    if set(data) != {"schema_version", "discovered_at", "denied", "variants"}:
        raise ValueError("lock has missing or unknown top-level fields")
    if not isinstance(data.get("discovered_at"), str) or not data["discovered_at"]:
        raise ValueError("lock discovered_at must be a non-empty string")
    if not isinstance(data.get("denied"), list) or not isinstance(data.get("variants"), list) or not data["variants"]:
        raise ValueError("lock denied/variants must be lists and variants must not be empty")

    seen_pairs = set()
    seen_ids = set()
    for index, variant in enumerate(data["variants"]):
        if not isinstance(variant, dict) or set(variant) != VARIANT_KEYS:
            raise ValueError(f"variant {index} has missing or unknown fields")
        app = variant.get("app")
        contract = APP_CONTRACTS.get(app)
        if contract is None:
            raise ValueError(f"variant {index} has unsupported app")
        major = variant.get("major_minor")
        version = variant.get("resolved_version")
        variant_id = variant.get("variant_id")
        if not isinstance(major, str) or not contract["major"].fullmatch(major):
            raise ValueError(f"variant {index} has invalid major_minor")
        if not isinstance(version, str) or not VERSION_RE.fullmatch(version):
            raise ValueError(f"variant {index} has invalid resolved_version")
        expected_version_prefix = major.split(".") if app != "typo3" else [major]
        if version.split(".")[:len(expected_version_prefix)] != expected_version_prefix:
            raise ValueError(f"variant {index} version does not match its major")
        if variant_id != f"{contract['prefix']}{major}":
            raise ValueError(f"variant {index} has noncanonical variant_id")
        for key in ("port", "doc_root", "max_body"):
            if variant.get(key) != contract[key]:
                raise ValueError(f"variant {index} has invalid {key}")
        pair = (app, major)
        if pair in seen_pairs or variant_id in seen_ids:
            raise ValueError(f"variant {index} is duplicated")
        seen_pairs.add(pair)
        seen_ids.add(variant_id)

    for index, denied in enumerate(data["denied"]):
        if not isinstance(denied, dict) or set(denied) != {"app", "major_minor", "reason"}:
            raise ValueError(f"denied entry {index} has invalid fields")
        contract = APP_CONTRACTS.get(denied.get("app"))
        if contract is None or not isinstance(denied.get("major_minor"), str) or not contract["major"].fullmatch(denied["major_minor"]):
            raise ValueError(f"denied entry {index} has invalid app/version")
        if not isinstance(denied.get("reason"), str) or not denied["reason"].strip():
            raise ValueError(f"denied entry {index} requires a reason")
    return data


def _fetch_json(url):
    """
    Fetch URL via curl (subprocess) and json.loads the body.

    Why curl, not urllib: urllib picks the first getaddrinfo result and
    doesn't fall back, so on hosts with broken IPv6 routing it hangs
    until the timeout fires. curl does Happy Eyeballs and degrades to
    IPv4 cleanly, which is what every other shell-out in the bake
    pipeline relies on too.
    """
    try:
        out = subprocess.run(
            [
                "curl", "-q", "-sfSL",
                "--max-time", str(HTTP_TIMEOUT_S),
                "-A", "devshot-lamp-discovery/1",
                url,
            ],
            capture_output=True,
            check=True,
            timeout=HTTP_TIMEOUT_S + 5,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as error:
        stderr = getattr(error, "stderr", b"") or b""
        detail = stderr.decode(errors="replace").strip() if isinstance(stderr, bytes) else str(stderr).strip()
        raise DiscoveryError(f"curl failed for {url}: {detail or type(error).__name__}") from error
    try:
        return json.loads(out.stdout)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise DiscoveryError(f"invalid JSON from {url}") from error


def _run_discovery(fn):
    try:
        return fn()
    except DiscoveryError:
        raise
    except (KeyError, TypeError, AttributeError, IndexError, ValueError) as error:
        raise DiscoveryError(f"invalid upstream payload: {error}") from error


def _parse_packagist_time(s):
    """Packagist returns ISO 8601 with `+00:00` already."""
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def _version_tuple(v):
    """Parse "6.9.4" → (6,9,4). Non-numeric segments → 0."""
    out = []
    for p in v.split("."):
        try:
            out.append(int(p))
        except ValueError:
            out.append(0)
    return tuple(out)


# ── WordPress ──────────────────────────────────────────────────────────────
def discover_wordpress():
    """
    WordPress stable-check returns {"X.Y.Z": "latest"|"outdated"|"insecure"}.
    Filter to status in ('latest', 'outdated') — those are versions WP
    still considers safe to run. Group by major.minor and keep the
    highest patch in each group.

    The API doesn't return per-version dates. The "not insecure" filter
    is the closest upstream-blessed analogue of "actively maintained".
    """
    data = _fetch_json("https://api.wordpress.org/core/stable-check/1.0/")
    by_mm = defaultdict(list)
    for v, status in data.items():
        if status == "insecure":
            continue
        parts = v.split(".")
        if len(parts) < 2:
            continue
        try:
            mm = f"{int(parts[0])}.{int(parts[1])}"
        except ValueError:
            continue
        by_mm[mm].append(v)
    out = []
    for mm, versions in by_mm.items():
        versions.sort(key=_version_tuple)
        latest = versions[-1]
        out.append({
            "app": "wordpress",
            "major_minor": mm,
            "resolved_version": latest,
            "variant_id": f"wp-{mm}",
            "port": 80,
            "doc_root": "/var/www/wordpress",
            "max_body": "64M",
        })
    out.sort(key=lambda e: _version_tuple(e["major_minor"]), reverse=True)
    # Cap at WP_MAX_MAJORS newest. WordPress backports security to a
    # very long tail (~25 majors) but real users only ever touch the
    # latest few. The cap keeps the matrix down to a sensible size.
    return out[:WP_MAX_MAJORS]


# ── Shopware ───────────────────────────────────────────────────────────────
def discover_shopware(now):
    """
    Packagist p2 endpoint lists every release of shopware/production with
    a `time` field. Drop pre-release tags, drop anything outside the
    support window, group by major.minor, keep latest patch per group.
    """
    data = _fetch_json("https://repo.packagist.org/p2/shopware/production.json")
    versions = data["packages"]["shopware/production"]
    cutoff = now - timedelta(days=SUPPORT_WINDOW_DAYS)
    by_mm = defaultdict(list)
    for entry in versions:
        v = entry["version"].lstrip("v")
        if any(tag in v.lower() for tag in ("dev", "rc", "beta", "alpha")):
            continue
        parts = v.split(".")
        if len(parts) < 2:
            continue
        try:
            mm = f"{int(parts[0])}.{int(parts[1])}"
        except ValueError:
            continue
        t = _parse_packagist_time(entry.get("time", ""))
        if not t or t < cutoff:
            continue
        by_mm[mm].append(v)
    out = []
    for mm, versions in by_mm.items():
        versions.sort(key=_version_tuple)
        latest = versions[-1]
        out.append({
            "app": "shopware",
            "major_minor": mm,
            "resolved_version": latest,
            "variant_id": f"sw-{mm}",
            "port": 81,
            "doc_root": "/var/www/shopware/public",
            "max_body": "128M",
        })
    out.sort(key=lambda e: _version_tuple(e["major_minor"]), reverse=True)
    return out


# ── TYPO3 ──────────────────────────────────────────────────────────────────
def discover_typo3(now):
    """
    TYPO3 ships one major every ~18 months and most users live on the
    LTS. We collapse to one variant per major (not per major.minor) —
    keep the highest patch released within the window.
    """
    data = _fetch_json(
        "https://repo.packagist.org/p2/typo3/cms-base-distribution.json"
    )
    versions = data["packages"]["typo3/cms-base-distribution"]
    cutoff = now - timedelta(days=SUPPORT_WINDOW_DAYS)
    by_major = defaultdict(list)
    for entry in versions:
        v = entry["version"].lstrip("v")
        if any(tag in v.lower() for tag in ("dev", "rc", "beta", "alpha")):
            continue
        parts = v.split(".")
        if not parts:
            continue
        try:
            major = int(parts[0])
        except ValueError:
            continue
        t = _parse_packagist_time(entry.get("time", ""))
        if not t or t < cutoff:
            continue
        by_major[major].append(v)
    out = []
    for major, versions in by_major.items():
        versions.sort(key=_version_tuple)
        latest = versions[-1]
        out.append({
            "app": "typo3",
            "major_minor": str(major),
            "resolved_version": latest,
            "variant_id": f"t3-v{major}",
            "port": 82,
            "doc_root": "/var/www/typo3/public",
            "max_body": "64M",
        })
    out.sort(key=lambda e: int(e["major_minor"]), reverse=True)
    return out


# ── Entry point ────────────────────────────────────────────────────────────
def main(argv):
    if len(argv) == 3 and argv[1] == "--validate-lock":
        try:
            validate_lock_data(json.loads(Path(argv[2]).read_text()))
        except (OSError, json.JSONDecodeError, ValueError) as error:
            print(f"ERROR: invalid LAMP discovery lock: {error}", file=sys.stderr)
            return 2
        return 0
    if len(argv) < 2:
        print("usage: discover-lamp-variants.py <build-dir>", file=sys.stderr)
        return 2
    build_dir = Path(argv[1])
    build_dir.mkdir(parents=True, exist_ok=True)
    lock_file = build_dir / "lamp-matrix.lock.json"
    now = datetime.now(timezone.utc)

    # Each app's discovery is independent — if one upstream is down,
    # the others still surface. Failed apps fall back to the lock file
    # entries for that app (if any).
    discovered = {}
    errors = []
    for label, fn in (
        ("wordpress", lambda: discover_wordpress()),
        ("shopware",  lambda: discover_shopware(now)),
        ("typo3",     lambda: discover_typo3(now)),
    ):
        try:
            discovered[label] = _run_discovery(fn)
        except DiscoveryError as e:
            errors.append((label, repr(e)))
            discovered[label] = None

    # Lock-file fallback for any app that failed.
    if any(v is None for v in discovered.values()):
        if lock_file.exists():
            try:
                with open(lock_file) as f:
                    prior = validate_lock_data(json.load(f))["variants"]
            except (OSError, json.JSONDecodeError, ValueError) as error:
                print(f"ERROR: refusing invalid fallback lock: {error}", file=sys.stderr)
                return 1
            for label in discovered:
                if discovered[label] is None:
                    fallback = [v for v in prior if v["app"] == label]
                    if not fallback:
                        print(f"ERROR: discovery failed for {label} and fallback lock has no entries for it", file=sys.stderr)
                        return 1
                    discovered[label] = fallback
                    print(
                        f"WARN: discovery failed for {label}; using "
                        f"{len(discovered[label])} entries from lock file",
                        file=sys.stderr,
                    )
        else:
            for label, err in errors:
                print(f"ERROR: {label} discovery failed: {err}", file=sys.stderr)
            print(
                f"ERROR: no lock file at {lock_file} to fall back to",
                file=sys.stderr,
            )
            return 1

    matrix = []
    for label in ("wordpress", "shopware", "typo3"):
        matrix.extend(discovered[label] or [])

    matrix = [v for v in matrix if (v["app"], v["major_minor"]) not in DENY]

    lock_data = {
        "schema_version": 1,
        "discovered_at": now.isoformat(),
        "denied": [
            {"app": a, "major_minor": m, "reason": "see spec 058"}
            for a, m in sorted(DENY)
        ],
        "variants": matrix,
    }
    try:
        validate_lock_data(lock_data)
    except ValueError as error:
        print(f"ERROR: live discovery produced an unsafe matrix: {error}", file=sys.stderr)
        return 1
    with open(lock_file, "w") as f:
        json.dump(lock_data, f, indent=2)
        f.write("\n")

    json.dump(matrix, sys.stdout, indent=2)
    print()

    by_app = defaultdict(int)
    for v in matrix:
        by_app[v["app"]] += 1
    summary = ", ".join(f"{n} {a}" for a, n in sorted(by_app.items()))
    print(f"\n# Discovered {len(matrix)} variants ({summary})", file=sys.stderr)
    print(f"# Lock written: {lock_file}", file=sys.stderr)
    if errors:
        for label, err in errors:
            print(f"# WARN: {label} fell back to lock — error: {err}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

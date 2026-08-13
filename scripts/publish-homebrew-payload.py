#!/usr/bin/env python3
"""Publish an exact, immutable Homebrew payload as a Docker registry object."""

from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import stat
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request


HEX40 = re.compile(r"^[0-9a-f]{40}$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
INTEGER = re.compile(r"^[0-9]+$")
REFERENCE = re.compile(r"^(?P<repository>[a-z0-9]+(?:[._-][a-z0-9]+)*/[a-z0-9]+(?:[._-][a-z0-9]+)*):(?P<tag>homebrew-arm64-(?P<sha>[0-9a-f]{40})-(?P<attempt>[0-9]+))$")
PAYLOAD_FILES = (
    "SHA256SUMS",
    "boot/Image-domu",
    "boot/devshot-guest-base.qcow2",
    "devshot-agent",
    "orchestrator-mac.qcow2",
    "provenance.json",
)


def fail(message: str) -> "NoReturn":
    raise ValueError(message)


def digest_file(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return "sha256:" + value.hexdigest()


def digest_bytes(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def validate_payload(payload: Path) -> None:
    if not payload.is_dir() or payload.is_symlink():
        fail("payload directory must be a real directory")
    actual = sorted(
        str(path.relative_to(payload))
        for path in payload.rglob("*")
        if path.is_file() or path.is_symlink()
    )
    if actual != sorted(PAYLOAD_FILES):
        fail(f"payload contains unexpected files: {actual}")
    directories = sorted(str(path.relative_to(payload)) for path in payload.rglob("*") if path.is_dir())
    if directories != ["boot"]:
        fail(f"payload contains unexpected directories: {directories}")
    for name in PAYLOAD_FILES:
        path = payload / name
        mode = path.lstat().st_mode
        if not stat.S_ISREG(mode) or path.is_symlink() or path.stat().st_size <= 0:
            fail(f"payload file must be a non-empty regular file: {name}")


def build_layer(payload: Path, raw_tar: Path, compressed_tar: Path) -> None:
    with tarfile.open(raw_tar, "w") as archive:
        for directory in ("payload", "payload/boot"):
            info = tarfile.TarInfo(directory + "/")
            info.type = tarfile.DIRTYPE
            info.mode = 0o700
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = 0
            archive.addfile(info)
        for name in PAYLOAD_FILES:
            source = payload / name
            info = tarfile.TarInfo(f"payload/{name}")
            info.size = source.stat().st_size
            info.mode = 0o600
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = 0
            with source.open("rb") as handle:
                archive.addfile(info, handle)
    with raw_tar.open("rb") as source, compressed_tar.open("xb") as raw_output:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw_output, mtime=0) as output:
            while chunk := source.read(1024 * 1024):
                output.write(chunk)


def build_config(args: argparse.Namespace, diff_id: str) -> bytes:
    labels = {
        "io.devshot.homebrew-payload.agent-sha": args.agent_sha,
        "io.devshot.homebrew-payload.image-digest": args.image_digest,
        "io.devshot.homebrew-payload.repository": "devshotcom/devshot-agent",
        "io.devshot.homebrew-payload.run-attempt": args.run_attempt,
        "io.devshot.homebrew-payload.run-id": args.run_id,
        "io.devshot.homebrew-payload.schema": "1",
    }
    return json.dumps(
        {
            "architecture": "arm64",
            "config": {"Labels": labels},
            "os": "linux",
            "rootfs": {"diff_ids": [diff_id], "type": "layers"},
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode()


def build_manifest(config: bytes, layer: Path) -> bytes:
    return json.dumps(
        {
            "config": {
                "digest": digest_bytes(config),
                "mediaType": "application/vnd.docker.container.image.v1+json",
                "size": len(config),
            },
            "layers": [
                {
                    "digest": digest_file(layer),
                    "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
                    "size": layer.stat().st_size,
                }
            ],
            "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
            "schemaVersion": 2,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode()


class Registry:
    def __init__(self, base: str, repository: str, token: str):
        self.base = base.rstrip("/") + f"/v2/{repository}"
        self.token = token

    def open(
        self,
        url: str,
        method: str = "GET",
        data: bytes | None = None,
        content_type: str = "",
        accept: str = "",
    ):
        headers = {"Authorization": f"Bearer {self.token}", "User-Agent": "devshot-homebrew-payload-publisher"}
        if content_type:
            headers["Content-Type"] = content_type
        if accept:
            headers["Accept"] = accept
        request = urllib.request.Request(url, headers=headers, data=data, method=method)
        return urllib.request.urlopen(request, timeout=180)

    def manifest_digest(self, tag: str) -> str:
        try:
            with self.open(
                f"{self.base}/manifests/{tag}",
                method="HEAD",
                accept="application/vnd.docker.distribution.manifest.v2+json",
            ) as response:
                return response.headers.get("Docker-Content-Digest", "")
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return ""
            raise

    def blob_exists(self, digest: str) -> bool:
        try:
            with self.open(f"{self.base}/blobs/{digest}", method="HEAD") as response:
                return response.status == 200
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return False
            raise

    def upload_blob(self, path: Path, digest: str) -> None:
        if self.blob_exists(digest):
            return
        with self.open(f"{self.base}/blobs/uploads/", method="POST", data=b"") as response:
            if response.status != 202:
                fail(f"registry upload start returned HTTP {response.status}")
            location = response.headers.get("Location", "")
        if not location:
            fail("registry upload start returned no location")
        upload_url = urllib.parse.urljoin(self.base + "/", location)
        parsed = urllib.parse.urlsplit(upload_url)
        query = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
        query.append(("digest", digest))
        target = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path, urllib.parse.urlencode(query), parsed.fragment))
        connection_type = http.client.HTTPSConnection if parsed.scheme == "https" else http.client.HTTPConnection
        connection = connection_type(parsed.hostname, parsed.port, timeout=900)
        try:
            connection.putrequest("PUT", urllib.parse.urlsplit(target).path + "?" + urllib.parse.urlsplit(target).query)
            connection.putheader("Authorization", f"Bearer {self.token}")
            connection.putheader("Content-Type", "application/octet-stream")
            connection.putheader("Content-Length", str(path.stat().st_size))
            connection.endheaders()
            with path.open("rb") as source:
                while chunk := source.read(1024 * 1024):
                    connection.send(chunk)
            response = connection.getresponse()
            response.read()
            if response.status != 201:
                fail(f"registry blob upload returned HTTP {response.status}")
        finally:
            connection.close()

    def publish_manifest(self, tag: str, manifest: bytes) -> str:
        with self.open(
            f"{self.base}/manifests/{tag}",
            method="PUT",
            data=manifest,
            content_type="application/vnd.docker.distribution.manifest.v2+json",
        ) as response:
            if response.status != 201:
                fail(f"registry manifest publication returned HTTP {response.status}")
            return response.headers.get("Docker-Content-Digest", "")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--payload-dir", required=True, type=Path)
    parser.add_argument("--reference", required=True)
    parser.add_argument("--agent-sha", required=True)
    parser.add_argument("--image-digest", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--run-attempt", required=True)
    parser.add_argument("--registry", default="https://registry-1.docker.io")
    parser.add_argument("--auth", default="https://auth.docker.io/token")
    args = parser.parse_args()
    match = REFERENCE.fullmatch(args.reference)
    if not match or match.group("repository") != "anticipatercom/devshot" or match.group("sha") != args.agent_sha or match.group("attempt") != args.run_attempt:
        fail("payload reference does not match the exact downstream identity")
    args.repository = match.group("repository")
    args.tag = match.group("tag")
    for value, pattern, label in (
        (args.agent_sha, HEX40, "agent SHA"),
        (args.image_digest, DIGEST, "image digest"),
        (args.run_id, INTEGER, "run ID"),
        (args.run_attempt, INTEGER, "run attempt"),
    ):
        if not pattern.fullmatch(value):
            fail(f"invalid {label}")
    return args


def main() -> int:
    try:
        args = parse_args()
        username = os.environ.get("DOCKERHUB_USERNAME", "")
        password = os.environ.get("DOCKERHUB_TOKEN", "")
        if not username or not password:
            fail("Docker Hub publication credentials are required")
        payload = args.payload_dir.resolve(strict=True)
        validate_payload(payload)
        with tempfile.TemporaryDirectory(prefix="devshot-homebrew-publish-") as directory:
            temporary = Path(directory)
            raw_layer = temporary / "payload.tar"
            layer = temporary / "payload.tar.gz"
            build_layer(payload, raw_layer, layer)
            config = build_config(args, digest_file(raw_layer))
            config_path = temporary / "config.json"
            config_path.write_bytes(config)
            manifest = build_manifest(config, layer)
            expected_manifest_digest = digest_bytes(manifest)

            credentials = base64.b64encode(f"{username}:{password}".encode()).decode()
            auth_url = args.auth + "?" + urllib.parse.urlencode(
                {"service": "registry.docker.io", "scope": f"repository:{args.repository}:pull,push"}
            )
            auth_request = urllib.request.Request(auth_url, headers={"Authorization": f"Basic {credentials}", "User-Agent": "devshot-homebrew-payload-publisher"})
            with urllib.request.urlopen(auth_request, timeout=60) as response:
                auth = json.load(response)
            token = auth.get("token") if isinstance(auth, dict) else ""
            if not isinstance(token, str) or not token:
                fail("registry authorization returned no publication token")

            registry = Registry(args.registry, args.repository, token)
            existing = registry.manifest_digest(args.tag)
            if existing:
                if existing != expected_manifest_digest:
                    fail("immutable Homebrew payload tag conflicts with a different manifest")
                print(existing)
                return 0
            registry.upload_blob(config_path, digest_bytes(config))
            registry.upload_blob(layer, digest_file(layer))
            published = registry.publish_manifest(args.tag, manifest)
            if published != expected_manifest_digest or registry.manifest_digest(args.tag) != expected_manifest_digest:
                fail("published Homebrew payload manifest did not verify exactly")
            print(expected_manifest_digest)
            return 0
    except (OSError, ValueError, KeyError, json.JSONDecodeError, tarfile.TarError, urllib.error.URLError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

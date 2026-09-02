#!/usr/bin/env python3
"""Upload a validated New API backup and encrypted production config to COS.

Credentials are read only from the server-side environment file by the caller.
This module deliberately never prints credential values or SDK exception text.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from qcloud_cos import CosConfig, CosS3Client


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"missing required COS setting: {name}")
    return value


def upload_and_verify(
    client: CosS3Client,
    bucket: str,
    path: Path,
    key: str,
    content_type: str,
) -> None:
    with path.open("rb") as body:
        client.put_object(
            Bucket=bucket,
            Body=body,
            Key=key,
            ContentType=content_type,
        )
    metadata = client.head_object(Bucket=bucket, Key=key)
    expected = path.stat().st_size
    try:
        actual = int(metadata.get("Content-Length", -1))
    except (TypeError, ValueError):
        actual = -1
    if actual != expected:
        raise RuntimeError(f"COS object size check failed for {key}")
    print(f"COS object verified: {key} ({expected} bytes)")


def build_client() -> tuple[CosS3Client, str]:
    secret_id = required("COS_SECRET_ID")
    secret_key = required("COS_SECRET_KEY")
    region = required("COS_REGION")
    bucket = required("COS_BUCKET")
    token = os.environ.get("COS_SESSION_TOKEN", "").strip() or None
    config = CosConfig(
        Region=region,
        SecretId=secret_id,
        SecretKey=secret_key,
        Token=token,
    )
    return CosS3Client(config), bucket


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dump", type=Path, required=True)
    parser.add_argument("--dump-checksum", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--timestamp", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    for path in (args.dump, args.dump_checksum, args.config):
        if not path.is_file():
            print(f"COS upload input is missing: {path}", file=sys.stderr)
            return 1

    try:
        client, bucket = build_client()
        year = args.timestamp[:4]
        month = args.timestamp[4:6]
        stem = f"new-api-{args.timestamp}.dump.gz"
        prefix = f"postgres/{year}/{month}"
        upload_and_verify(
            client,
            bucket,
            args.dump,
            f"{prefix}/{stem}",
            "application/octet-stream",
        )
        upload_and_verify(
            client,
            bucket,
            args.dump_checksum,
            f"{prefix}/{stem}.sha256",
            "text/plain; charset=utf-8",
        )
        upload_and_verify(
            client,
            bucket,
            args.config,
            "config/new-api-env.enc",
            "application/octet-stream",
        )
    except Exception as exc:  # noqa: BLE001 - never expose SDK request details
        print(f"COS backup upload failed: {type(exc).__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

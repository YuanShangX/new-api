#!/usr/bin/env python3
"""Apply idempotent versioning and lifecycle rules to the backup bucket."""

from __future__ import annotations

import os
import sys

from qcloud_cos import CosConfig, CosS3Client


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"missing required COS setting: {name}")
    return value


def main() -> int:
    try:
        token = os.environ.get("COS_SESSION_TOKEN", "").strip() or None
        bucket = required("COS_BUCKET")
        client = CosS3Client(
            CosConfig(
                Region=required("COS_REGION"),
                SecretId=required("COS_SECRET_ID"),
                SecretKey=required("COS_SECRET_KEY"),
                Token=token,
            )
        )
        client.put_bucket_versioning(Bucket=bucket, Status="Enabled")
        versioning = client.get_bucket_versioning(Bucket=bucket)
        if str(versioning.get("Status", "")) != "Enabled":
            raise RuntimeError("COS bucket versioning was not enabled")

        managed_rules = [
            {
                "ID": "new-api-postgres-current-90d",
                "Filter": {"Prefix": "postgres/"},
                "Status": "Enabled",
                "Expiration": {"Days": 90},
                "NoncurrentVersionExpiration": {"NoncurrentDays": 30},
            },
            {
                "ID": "new-api-config-current-90d",
                "Filter": {"Prefix": "config/"},
                "Status": "Enabled",
                "Expiration": {"Days": 90},
                "NoncurrentVersionExpiration": {"NoncurrentDays": 30},
            },
        ]
        # COS replaces the complete lifecycle document on PUT. Preserve rules
        # that may belong to another owner and only replace our two rule IDs.
        try:
            existing = client.get_bucket_lifecycle(Bucket=bucket)
            existing_rules = existing.get("Rule", [])
            if isinstance(existing_rules, dict):
                existing_rules = [existing_rules]
        except Exception:
            existing_rules = []
        managed_ids = {rule["ID"] for rule in managed_rules}
        preserved_rules = [
            rule for rule in existing_rules if str(rule.get("ID", "")) not in managed_ids
        ]
        lifecycle = {"Rule": preserved_rules + managed_rules}
        client.put_bucket_lifecycle(Bucket=bucket, LifecycleConfiguration=lifecycle)
        applied = client.get_bucket_lifecycle(Bucket=bucket)
        rules = applied.get("Rule", [])
        ids = {str(rule.get("ID", "")) for rule in rules}
        expected = {"new-api-postgres-current-90d", "new-api-config-current-90d"}
        if not expected.issubset(ids):
            raise RuntimeError("COS lifecycle verification failed")
    except Exception as exc:  # noqa: BLE001 - never expose SDK request details
        print(f"COS bucket configuration failed: {type(exc).__name__}", file=sys.stderr)
        return 1

    print("COS bucket versioning: enabled")
    print("COS lifecycle: postgres/ and config/ current objects 90 days; noncurrent versions 30 days")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

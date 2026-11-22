#!/usr/bin/env python3
"""Recover durable Storage objects from retained S3 versions before database promotion."""

import argparse
import base64
import hashlib
import json
import os
import re
import sys
import tempfile
from contextlib import closing
from dataclasses import asdict, dataclass, fields
from pathlib import Path
from urllib.parse import urlsplit


UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
ATTACHMENT_KEY = re.compile(rf"org/{UUID}/{UUID}")
PROFILE_MEDIA_KEY = re.compile(rf"profile-media/candidate/{UUID}")
MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024
MAX_PROFILE_MEDIA_BYTES = 5 * 1024 * 1024
PLAN_FORMAT = "cadenway-storage-restore-v1"
OBJECT_HEADERS = (
    "CacheControl",
    "ContentDisposition",
    "ContentEncoding",
    "ContentLanguage",
    "ContentType",
    "Expires",
    "Metadata",
)


class RestoreError(Exception):
    """An operator-safe failure message without object identifiers or credentials."""


@dataclass(frozen=True)
class PlanEntry:
    key: str
    size: int
    source_version: str
    etag: str
    latest_version: str
    deleted: bool


def check_object(key, size):
    if not isinstance(key, str) or type(size) is not int or size < 1:
        raise RestoreError("Invalid durable object entry in restore data.")
    if ATTACHMENT_KEY.fullmatch(key) and size <= MAX_ATTACHMENT_BYTES:
        return
    if PROFILE_MEDIA_KEY.fullmatch(key) and size <= MAX_PROFILE_MEDIA_BYTES:
        return
    raise RestoreError("Unexpected durable object key or size in restore data.")


def valid_header(value):
    return (
        isinstance(value, str)
        and 0 < len(value) <= 1024
        and value.isascii()
        and all(32 < ord(character) < 127 for character in value)
    )


def unique_fields(pairs):
    record = dict(pairs)
    if len(record) != len(pairs):
        raise RestoreError("Duplicate JSON fields in storage restore data.")
    return record


def read_records(path):
    with path.open(encoding="utf-8") as stream:
        for line in stream:
            record = json.loads(line, object_pairs_hook=unique_fields)
            if not isinstance(record, dict):
                raise RestoreError("Invalid JSON record in storage restore data.")
            yield record


def read_manifest(path):
    entries = {}
    for record in read_records(path):
        if set(record) != {"key", "size"}:
            raise RestoreError("Invalid storage restore manifest fields.")
        key, size = record["key"], record["size"]
        check_object(key, size)
        if entries.setdefault(key, size) != size:
            raise RestoreError(
                "Conflicting sizes for a durable object in the database dump."
            )
    return entries


def add_conditional_write_header(request, **_):
    request.headers["If-None-Match"] = "*"


def conditional_put_args(client):
    put = client.meta.service_model.operation_model("PutObject")
    if "IfNoneMatch" in put.input_shape.members:
        return {"IfNoneMatch": "*"}
    # Older distro SDK models do not expose this header. Sign it on this client only.
    client.meta.events.register(
        "before-sign.s3.PutObject", add_conditional_write_header
    )
    return {}


class ObjectRestore:
    def __init__(self, client, *, endpoint, region, bucket, addressing_style, put_args):
        self.client = client
        self.bucket = bucket
        self.put_args = put_args
        self.plan_header = {
            "format": PLAN_FORMAT,
            "endpoint": endpoint,
            "region": region,
            "bucket": bucket,
            "addressing_style": addressing_style,
        }

    def check_versioning(self):
        versioning = self.client.get_bucket_versioning(Bucket=self.bucket)
        if versioning.get("Status") != "Enabled":
            raise RestoreError(
                "The application bucket must have S3 versioning enabled."
            )

    def inventory(self, key, size):
        physical = {}
        latest = []
        version_ids = set()
        paginator = self.client.get_paginator("list_object_versions")
        for page in paginator.paginate(Bucket=self.bucket, Prefix=key):
            for field in ("Versions", "DeleteMarkers"):
                deleted = field == "DeleteMarkers"
                for item in page.get(field, []):
                    if item.get("Key") != key:
                        continue
                    version = item.get("VersionId")
                    is_latest = item.get("IsLatest")
                    if not valid_header(version) or type(is_latest) is not bool:
                        raise RestoreError(
                            "S3 returned an invalid durable object version."
                        )
                    if version in version_ids:
                        raise RestoreError(
                            "S3 returned duplicate durable object version identifiers."
                        )
                    version_ids.add(version)
                    if not deleted:
                        etag = item.get("ETag")
                        if item.get("Size") != size or not valid_header(etag):
                            raise RestoreError(
                                "A retained S3 version conflicts with the database dump."
                            )
                        physical[version] = etag
                    if is_latest:
                        latest.append((version, deleted))
        if not physical:
            raise RestoreError("A durable object has no retained S3 payload version.")
        if len(latest) != 1 or len(set(physical.values())) != 1:
            raise RestoreError("A durable object has ambiguous S3 history.")
        latest_version, deleted = latest[0]
        return physical, latest_version, deleted

    def check_current(self, key, size, version, etag):
        current = self.client.head_object(Bucket=self.bucket, Key=key)
        if (
            current.get("VersionId") != version
            or current.get("ETag") != etag
            or current.get("ContentLength") != size
        ):
            raise RestoreError("The current S3 object changed during storage restore.")

    def plan(self, manifest_path, plan_path):
        manifest = read_manifest(manifest_path)
        self.check_versioning()
        temporary_path = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w", encoding="utf-8", dir=plan_path.parent, delete=False
            ) as stream:
                temporary_path = Path(stream.name)
                stream.write(json.dumps(self.plan_header) + "\n")
                for key, size in manifest.items():
                    physical, latest, deleted = self.inventory(key, size)
                    source = next(iter(physical)) if deleted else latest
                    etag = physical[source]
                    if not deleted:
                        self.check_current(key, size, latest, etag)
                    entry = PlanEntry(key, size, source, etag, latest, deleted)
                    stream.write(json.dumps(asdict(entry)) + "\n")
            os.replace(temporary_path, plan_path)
        finally:
            if temporary_path is not None:
                temporary_path.unlink(missing_ok=True)
        return len(manifest)

    def read_plan(self, plan_path):
        entries = {}
        expected_fields = {field.name for field in fields(PlanEntry)}
        records = read_records(plan_path)
        if next(records, None) != self.plan_header:
            raise RestoreError(
                "The storage restore plan does not match the application bucket."
            )
        for record in records:
            if set(record) != expected_fields:
                raise RestoreError("Invalid storage restore plan fields.")
            entry = PlanEntry(**record)
            check_object(entry.key, entry.size)
            if (
                type(entry.deleted) is not bool
                or not valid_header(entry.source_version)
                or not valid_header(entry.etag)
                or not valid_header(entry.latest_version)
                or entry.deleted == (entry.source_version == entry.latest_version)
                or entry.key in entries
            ):
                raise RestoreError(
                    "Invalid durable object entry in storage restore plan."
                )
            entries[entry.key] = entry
        return entries.values()

    def write_missing(self, entry):
        source = self.client.get_object(
            Bucket=self.bucket,
            Key=entry.key,
            VersionId=entry.source_version,
            IfMatch=entry.etag,
        )
        with closing(source["Body"]) as body:
            if (
                source.get("VersionId") != entry.source_version
                or source.get("ETag") != entry.etag
                or source.get("ContentLength") != entry.size
            ):
                raise RestoreError(
                    "The retained S3 payload no longer matches the restore plan."
                )
            payload = body.read(entry.size + 1)
            if len(payload) != entry.size:
                raise RestoreError(
                    "The retained S3 payload did not have its expected size."
                )
        checksum = base64.b64encode(
            hashlib.md5(payload, usedforsecurity=False).digest()
        ).decode("ascii")
        metadata = {
            header: source[header] for header in OBJECT_HEADERS if header in source
        }
        result = self.client.put_object(
            Bucket=self.bucket,
            Key=entry.key,
            Body=payload,
            ContentLength=entry.size,
            ContentMD5=checksum,
            **self.put_args,
            **metadata,
        )
        version = result.get("VersionId")
        if (
            not valid_header(version)
            or version == "null"
            or result.get("ETag") != entry.etag
        ):
            raise RestoreError(
                "S3 did not confirm the restored payload fingerprint and version."
            )
        return version

    def apply(self, plan_path):
        entries = self.read_plan(plan_path)
        self.check_versioning()
        written = 0
        current = {}
        for entry in entries:
            physical, latest, deleted = self.inventory(entry.key, entry.size)
            if physical.get(entry.source_version) != entry.etag:
                raise RestoreError(
                    "The retained S3 payload no longer matches the restore plan."
                )
            if deleted:
                latest = self.write_missing(entry)
                written += 1
            current[entry.key] = latest
        for entry in entries:
            self.check_current(entry.key, entry.size, current[entry.key], entry.etag)
        return written


def make_restore():
    import boto3
    from botocore.config import Config

    prefix = "RESTORE_OBJECT_S3_"
    config = {
        name: os.environ.get(prefix + name)
        for name in (
            "ENDPOINT",
            "REGION",
            "BUCKET",
            "ACCESS_KEY_ID",
            "SECRET_ACCESS_KEY",
        )
    }
    if not all(config.values()):
        raise RestoreError(
            "The application bucket connection is missing required settings."
        )
    force_path_style = os.environ.get(prefix + "FORCE_PATH_STYLE", "false")
    addressing_style = {"true": "path", "false": "virtual"}.get(force_path_style)
    if addressing_style is None:
        raise RestoreError(
            "The application bucket addressing style setting is invalid."
        )
    endpoint = urlsplit(config["ENDPOINT"])
    if (
        endpoint.scheme not in {"http", "https"}
        or not endpoint.hostname
        or endpoint.username is not None
        or endpoint.password is not None
        or endpoint.query
        or endpoint.fragment
        or endpoint.path not in {"", "/"}
    ):
        raise RestoreError(
            "The application bucket needs an explicit, valid S3 endpoint."
        )
    client = boto3.client(
        "s3",
        endpoint_url=config["ENDPOINT"],
        region_name=config["REGION"],
        aws_access_key_id=config["ACCESS_KEY_ID"],
        aws_secret_access_key=config["SECRET_ACCESS_KEY"],
        config=Config(
            signature_version="s3v4",
            s3={"addressing_style": addressing_style},
            connect_timeout=10,
            read_timeout=60,
            retries={"mode": "standard", "total_max_attempts": 1},
        ),
    )
    return ObjectRestore(
        client,
        endpoint=config["ENDPOINT"],
        region=config["REGION"],
        bucket=config["BUCKET"],
        addressing_style=addressing_style,
        put_args=conditional_put_args(client),
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    operations = parser.add_subparsers(dest="operation", required=True)
    plan_parser = operations.add_parser("plan")
    plan_parser.add_argument("manifest", type=Path)
    plan_parser.add_argument("plan", type=Path)
    apply_parser = operations.add_parser("apply")
    apply_parser.add_argument("plan", type=Path)
    args = parser.parse_args()

    try:
        from botocore.exceptions import BotoCoreError, ClientError
    except ImportError:
        print("Storage restore requires the S3 Python SDK.", file=sys.stderr)
        return 1

    try:
        restore = make_restore()
        if args.operation == "plan":
            count = restore.plan(args.manifest, args.plan)
            print(f"Verified S3 version history for {count} durable objects.")
        else:
            count = restore.apply(args.plan)
            print(f"Restored {count} durable objects and verified current S3 versions.")
    except RestoreError as error:
        print(str(error), file=sys.stderr)
        return 1
    except ClientError as error:
        status = error.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
        if status in {409, 412}:
            print(
                "A conditional S3 request conflicted during storage restore.",
                file=sys.stderr,
            )
        else:
            print(
                "An application bucket S3 request failed during storage restore.",
                file=sys.stderr,
            )
        return 1
    except (BotoCoreError, ImportError, KeyError, OSError, TypeError, ValueError):
        print(
            "Storage restore could not validate data or complete an S3 request.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

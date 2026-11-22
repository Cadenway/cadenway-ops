import base64
import hashlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).parents[1] / "files" / "cadenway-restore-objects.py"
SPEC = importlib.util.spec_from_file_location("restore_objects", SCRIPT)
restore_objects = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = restore_objects
SPEC.loader.exec_module(restore_objects)

OBJECT_KEY = (
    "org/00000000-0000-4000-8000-000000000001/00000000-0000-4000-8000-000000000002"
)
PROFILE_KEY = "profile-media/candidate/00000000-0000-4000-8000-000000000003"
PAYLOAD = b"contents"
ETAG = '"original"'


def version(key, version_id, *, latest, size=len(PAYLOAD), etag=ETAG):
    return {
        "Key": key,
        "VersionId": version_id,
        "IsLatest": latest,
        "Size": size,
        "ETag": etag,
    }


def marker(key, version_id, *, latest):
    return {"Key": key, "VersionId": version_id, "IsLatest": latest}


class ConcurrentWrite(Exception):
    pass


class FakeS3:
    def __init__(self):
        self.versions = []
        self.markers = []
        self.status = "Enabled"
        self.gets = []
        self.puts = []
        self.heads = []
        self.before_put = None
        self.source_body = PAYLOAD

    def get_bucket_versioning(self, **_):
        return {"Status": self.status}

    def get_paginator(self, name):
        assert name == "list_object_versions"
        return self

    def paginate(self, *, Prefix, **_):
        for field, records in (
            ("DeleteMarkers", self.markers),
            ("Versions", self.versions),
        ):
            for record in records:
                if record["Key"].startswith(Prefix):
                    yield {field: [record]}

    def head_object(self, *, Key, **_):
        self.heads.append(Key)
        version = next(
            entry
            for entry in self.versions
            if entry["Key"] == Key and entry["IsLatest"]
        )
        return {
            "VersionId": version["VersionId"],
            "ContentLength": version["Size"],
            "ETag": version["ETag"],
        }

    def get_object(self, *, Key, VersionId, IfMatch, **_):
        self.gets.append((Key, VersionId, IfMatch))
        source = next(
            entry
            for entry in self.versions
            if entry["Key"] == Key and entry["VersionId"] == VersionId
        )
        return {
            "VersionId": source["VersionId"],
            "ContentLength": source["Size"],
            "ETag": source["ETag"],
            "Body": io.BytesIO(self.source_body),
            "ContentType": "image/png",
            "ContentDisposition": "inline",
            "Metadata": {"owner": "fixture"},
        }

    def put_object(self, *, Key, IfNoneMatch, **kwargs):
        assert IfNoneMatch == "*"
        if self.before_put is not None:
            self.before_put()
        if any(entry["Key"] == Key and entry["IsLatest"] for entry in self.versions):
            raise ConcurrentWrite
        for entry in self.markers:
            if entry["Key"] == Key:
                entry["IsLatest"] = False
        self.puts.append(kwargs)
        new_version = f"restored-{len(self.puts)}"
        self.versions.append(version(Key, new_version, latest=True))
        return {"VersionId": new_version, "ETag": ETAG}


class RestoreObjectsTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.manifest = Path(directory.name) / "manifest.jsonl"
        self.plan = Path(directory.name) / "plan.jsonl"
        self.s3 = FakeS3()
        self.options = {
            "endpoint": "http://s3.example.test",
            "region": "us-east-1",
            "bucket": "app-objects",
            "addressing_style": "path",
            "put_args": {"IfNoneMatch": "*"},
        }
        self.restore = restore_objects.ObjectRestore(self.s3, **self.options)

    def write_manifest(self, *objects):
        with self.manifest.open("w", encoding="utf-8") as stream:
            for key, size in objects:
                stream.write(json.dumps({"key": key, "size": size}) + "\n")

    def deleted_source(self, version_id="original"):
        self.write_manifest((OBJECT_KEY, len(PAYLOAD)))
        self.s3.versions.append(version(OBJECT_KEY, version_id, latest=False))
        self.s3.markers.append(marker(OBJECT_KEY, "deletion", latest=True))

    def test_restores_exact_key_across_pages_and_preserves_history_and_metadata(self):
        self.deleted_source("null")
        self.write_manifest((OBJECT_KEY, len(PAYLOAD)), (OBJECT_KEY, len(PAYLOAD)))
        self.s3.versions.insert(
            0, version(OBJECT_KEY + "-suffix", "other", latest=True, size=99)
        )
        self.s3.versions.append(version(OBJECT_KEY, "another-copy", latest=False))
        self.assertEqual(self.restore.plan(self.manifest, self.plan), 1)
        self.assertEqual(self.s3.gets, [])
        self.assertEqual(self.s3.puts, [])

        self.assertEqual(self.restore.apply(self.plan), 1)
        self.assertEqual(self.s3.gets, [(OBJECT_KEY, "null", ETAG)])
        self.assertEqual(self.s3.heads, [OBJECT_KEY])
        self.assertEqual(
            self.s3.markers, [marker(OBJECT_KEY, "deletion", latest=False)]
        )
        self.assertEqual(
            self.s3.puts[0],
            {
                "Bucket": "app-objects",
                "Body": PAYLOAD,
                "ContentLength": len(PAYLOAD),
                "ContentMD5": base64.b64encode(
                    hashlib.md5(PAYLOAD, usedforsecurity=False).digest()
                ).decode("ascii"),
                "ContentType": "image/png",
                "ContentDisposition": "inline",
                "Metadata": {"owner": "fixture"},
            },
        )
        self.assertEqual(self.restore.apply(self.plan), 0)
        self.assertEqual(len(self.s3.puts), 1)

    def test_current_object_is_checked_and_left_alone(self):
        self.write_manifest((PROFILE_KEY, len(PAYLOAD)))
        self.s3.versions.append(version(PROFILE_KEY, "original", latest=True))
        self.assertEqual(self.restore.plan(self.manifest, self.plan), 1)
        self.assertEqual(self.restore.apply(self.plan), 0)
        self.assertEqual(self.s3.heads, [PROFILE_KEY, PROFILE_KEY])
        self.assertEqual(self.s3.puts, [])

    def test_missing_source_or_divergent_history_fails_preflight(self):
        self.deleted_source()
        cases = (
            ([version(OBJECT_KEY + "-suffix", "other", latest=True)], "no retained"),
            ([version(OBJECT_KEY, "original", latest=False, size=99)], "conflicts"),
            (
                [
                    version(OBJECT_KEY, "original", latest=False),
                    version(OBJECT_KEY, "different", latest=False, etag='"different"'),
                ],
                "ambiguous",
            ),
            ([version(OBJECT_KEY, "original", latest=True)], "ambiguous"),
        )
        for versions, failure in cases:
            with self.subTest(failure=failure):
                self.s3.versions = versions
                with self.assertRaisesRegex(restore_objects.RestoreError, failure):
                    self.restore.plan(self.manifest, self.plan)
                self.assertFalse(self.plan.exists())
        self.assertEqual(self.s3.puts, [])

    def test_rejects_invalid_keys_sizes_and_conflicting_manifest_entries(self):
        cases = (
            (("uploads/temporary", 5),),
            ((OBJECT_KEY, True),),
            ((OBJECT_KEY, 0),),
            ((PROFILE_KEY, 5 * 1024 * 1024 + 1),),
            ((OBJECT_KEY, 25 * 1024 * 1024 + 1),),
            ((OBJECT_KEY, 5), (OBJECT_KEY, 1)),
        )
        for objects in cases:
            with self.subTest(objects=objects):
                self.write_manifest(*objects)
                with self.assertRaises(restore_objects.RestoreError):
                    self.restore.plan(self.manifest, self.plan)
        self.assertEqual(self.s3.puts, [])

    def test_refuses_bucket_without_versioning_or_different_plan_target(self):
        self.deleted_source()
        self.s3.status = "Suspended"
        with self.assertRaisesRegex(restore_objects.RestoreError, "versioning enabled"):
            self.restore.plan(self.manifest, self.plan)
        self.s3.status = "Enabled"
        self.restore.plan(self.manifest, self.plan)
        for changed_options in ({"bucket": "other"}, {"addressing_style": "virtual"}):
            target = restore_objects.ObjectRestore(
                self.s3, **(self.options | changed_options)
            )
            with self.assertRaisesRegex(
                restore_objects.RestoreError, "match the application bucket"
            ):
                target.apply(self.plan)
        self.assertEqual(self.s3.puts, [])

    def test_different_live_version_since_preflight_aborts_before_put(self):
        self.deleted_source()
        self.restore.plan(self.manifest, self.plan)
        self.s3.markers[0]["IsLatest"] = False
        self.s3.versions.append(
            version(OBJECT_KEY, "concurrent", latest=True, etag='"different"')
        )
        with self.assertRaisesRegex(
            restore_objects.RestoreError, "ambiguous S3 history"
        ):
            self.restore.apply(self.plan)
        self.assertEqual(self.s3.puts, [])

    def test_expired_source_version_aborts_even_if_an_identical_copy_remains(self):
        self.deleted_source()
        self.restore.plan(self.manifest, self.plan)
        self.s3.versions = [version(OBJECT_KEY, "remaining-copy", latest=False)]
        with self.assertRaisesRegex(restore_objects.RestoreError, "no longer matches"):
            self.restore.apply(self.plan)
        self.assertEqual(self.s3.puts, [])

    def test_conditional_put_rejects_race_after_reading_source(self):
        self.deleted_source()
        self.restore.plan(self.manifest, self.plan)

        def write_concurrently():
            self.s3.markers[0]["IsLatest"] = False
            self.s3.versions.append(version(OBJECT_KEY, "concurrent", latest=True))

        self.s3.before_put = write_concurrently
        with self.assertRaises(ConcurrentWrite):
            self.restore.apply(self.plan)
        self.assertEqual(self.s3.puts, [])
        self.assertEqual(self.s3.head_object(Key=OBJECT_KEY)["VersionId"], "concurrent")

    def test_rejects_duplicate_json_field_names(self):
        self.manifest.write_text(
            f'{{"key":"{OBJECT_KEY}","size":5,"size":10}}\n', encoding="utf-8"
        )
        with self.assertRaisesRegex(
            restore_objects.RestoreError, "Duplicate JSON fields"
        ):
            self.restore.plan(self.manifest, self.plan)
        self.assertFalse(self.plan.exists())

    def test_short_or_long_retained_payload_fails_before_put(self):
        self.deleted_source()
        self.restore.plan(self.manifest, self.plan)
        for payload in (PAYLOAD[:-1], PAYLOAD + b"x"):
            with self.subTest(size=len(payload)):
                self.s3.source_body = payload
                with self.assertRaisesRegex(
                    restore_objects.RestoreError, "expected size"
                ):
                    self.restore.apply(self.plan)
        self.assertEqual(self.s3.puts, [])

    def test_checks_written_version_is_still_current(self):
        self.deleted_source()
        self.restore.plan(self.manifest, self.plan)
        with patch.object(
            self.s3,
            "head_object",
            return_value={
                "VersionId": "concurrent",
                "ETag": ETAG,
                "ContentLength": len(PAYLOAD),
            },
        ):
            with self.assertRaisesRegex(
                restore_objects.RestoreError, "current S3 object changed"
            ):
                self.restore.apply(self.plan)

    def test_client_addressing_matches_storage_configuration(self):
        sdk = Mock()
        put = sdk.client.return_value.meta.service_model.operation_model.return_value
        put.input_shape.members = {"IfNoneMatch": {}}
        modules = {
            "boto3": sdk,
            "botocore": SimpleNamespace(),
            "botocore.config": SimpleNamespace(Config=lambda **kwargs: kwargs),
        }
        values = {
            "ENDPOINT": "https://s3.example.test",
            "REGION": "us-east-1",
            "BUCKET": "fixture-bucket",
            "ACCESS_KEY_ID": "fixture-key",
            "SECRET_ACCESS_KEY": "fixture-secret",
        }
        environment = {
            f"RESTORE_OBJECT_S3_{name}": value for name, value in values.items()
        }
        with (
            patch.dict(sys.modules, modules),
            patch.dict(os.environ, environment, clear=True),
        ):
            for force_path, style in (
                (None, "virtual"),
                ("false", "virtual"),
                ("true", "path"),
            ):
                with self.subTest(force_path=force_path):
                    if force_path is not None:
                        os.environ["RESTORE_OBJECT_S3_FORCE_PATH_STYLE"] = force_path
                    restore = restore_objects.make_restore()
                    self.assertEqual(restore.plan_header["addressing_style"], style)
                    self.assertEqual(restore.put_args, {"IfNoneMatch": "*"})
                    config = sdk.client.call_args.kwargs["config"]
                    self.assertEqual(config["s3"], {"addressing_style": style})
            os.environ["RESTORE_OBJECT_S3_FORCE_PATH_STYLE"] = "yes"
            with self.assertRaisesRegex(
                restore_objects.RestoreError, "addressing style"
            ):
                restore_objects.make_restore()

    def test_conditional_header_is_signed_with_legacy_sdk_model(self):
        try:
            import boto3
            from botocore.config import Config
        except ImportError:
            self.skipTest("requires boto3 to exercise request signing")

        class CapturedRequest(Exception):
            pass

        def inspect_signed_request(request, **_):
            self.assertEqual(request.headers["If-None-Match"], b"*")
            authorization = request.headers["Authorization"]
            self.assertIn(b"AWS4-HMAC-SHA256", authorization)
            self.assertIn(
                b"if-none-match",
                authorization.split(b"SignedHeaders=")[1].split(b",")[0],
            )
            raise CapturedRequest

        client = boto3.client(
            "s3",
            endpoint_url="http://127.0.0.1:9",
            region_name="us-east-1",
            aws_access_key_id="fixture-key",
            aws_secret_access_key="fixture-secret",
            config=Config(signature_version="s3v4"),
        )
        model = client.meta.service_model.operation_model(
            "PutObject"
        ).input_shape.members
        legacy = {name: field for name, field in model.items() if name != "IfNoneMatch"}
        with patch.dict(model, legacy, clear=True):
            put_args = restore_objects.conditional_put_args(client)
            self.assertEqual(put_args, {})
            client.meta.events.register(
                "before-send.s3.PutObject", inspect_signed_request
            )
            with self.assertRaises(CapturedRequest):
                client.put_object(
                    Bucket="fixture-bucket", Key=OBJECT_KEY, Body=PAYLOAD, **put_args
                )


if __name__ == "__main__":
    unittest.main()

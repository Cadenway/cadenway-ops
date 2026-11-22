"""Drive the disposable versioned S3 bucket used by the backup integration test."""

import json
import os
import sys
from urllib.error import HTTPError
from urllib.request import urlopen

import boto3
from botocore.config import Config

BUCKET = os.environ["STORAGE_S3_BUCKET"]
ATTACHMENT = os.environ["FIXTURE_ATTACHMENT_KEY"]
POST_DUMP = os.environ["FIXTURE_POST_DUMP_KEY"]
POST_DUMP_BYTES = b"uploaded after the dump"
REFERENCED = {
    ATTACHMENT: b"original attachment",
    os.environ["FIXTURE_INTAKE_KEY"]: b"original intake",
    f"profile-media/candidate/{os.environ['FIXTURE_PROFILE_ID']}": b"original avatar",
}
S3 = boto3.client(
    "s3",
    endpoint_url=os.environ["STORAGE_S3_ENDPOINT"],
    region_name=os.environ["STORAGE_S3_REGION"],
    aws_access_key_id=os.environ["STORAGE_RESTORE_S3_ACCESS_KEY_ID"],
    aws_secret_access_key=os.environ["STORAGE_RESTORE_S3_SECRET_ACCESS_KEY"],
    config=Config(
        signature_version="s3v4",
        s3={"addressing_style": "path"},
        retries={"total_max_attempts": 1},
        connect_timeout=2,
        read_timeout=5,
    ),
)


def put(key, data):
    return S3.put_object(Bucket=BUCKET, Key=key, Body=data)["VersionId"]


def download(key, version_id=None):
    params = {"Bucket": BUCKET, "Key": key}
    if version_id is not None:
        params["VersionId"] = version_id
    url = S3.generate_presigned_url("get_object", Params=params, ExpiresIn=60)
    with urlopen(url, timeout=5) as response:
        return response.read()


def ready():
    S3.list_buckets()


def seed():
    S3.create_bucket(Bucket=BUCKET)
    S3.put_bucket_versioning(
        Bucket=BUCKET, VersioningConfiguration={"Status": "Enabled"}
    )
    assert S3.get_bucket_versioning(Bucket=BUCKET)["Status"] == "Enabled"
    for key, data in REFERENCED.items():
        put(key, data)


def delete_after_dump():
    history = {}
    for key, data in REFERENCED.items():
        version_id = S3.head_object(Bucket=BUCKET, Key=key)["VersionId"]
        delete = S3.delete_object(Bucket=BUCKET, Key=key)
        assert delete["DeleteMarker"], f"missing delete marker for {key}"
        try:
            download(key)
        except HTTPError as error:
            assert error.code == 404, (
                f"unexpected download failure for {key}: {error.code}"
            )
        else:
            raise AssertionError(
                f"current download still available for deleted object {key}"
            )
        assert download(key, version_id) == data, f"historical download lost for {key}"
        history[key] = {"version": version_id, "marker": delete["VersionId"]}
    print(
        json.dumps({"removed": history, "post_dump": put(POST_DUMP, POST_DUMP_BYTES)})
    )


def version_history():
    entries = []
    for page in S3.get_paginator("list_object_versions").paginate(Bucket=BUCKET):
        for kind in ("Versions", "DeleteMarkers"):
            for item in page.get(kind, []):
                entries.append((item["Key"], kind, item["VersionId"], item["IsLatest"]))
    return sorted(entries)


def verify_restored():
    before = json.load(sys.stdin)
    entries = version_history()
    for key, data in REFERENCED.items():
        previous = before["removed"][key]
        assert (key, "Versions", previous["version"], False) in entries, (
            f"lost S3 version for {key}"
        )
        assert (key, "DeleteMarkers", previous["marker"], False) in entries, (
            f"lost marker for {key}"
        )
        assert sum(entry[0] == key for entry in entries) == 3, (
            f"extra S3 versions for {key}"
        )
        assert download(key) == data, f"incorrect restored download for {key}"
    assert (POST_DUMP, "Versions", before["post_dump"], True) in entries, (
        "new version overwritten"
    )
    assert download(POST_DUMP) == POST_DUMP_BYTES, "new upload changed"


def history():
    print(json.dumps(version_history()))


def conflict():
    data = b"changed attachment!"
    assert len(data) == len(REFERENCED[ATTACHMENT])
    put(ATTACHMENT, data)
    assert download(ATTACHMENT) == data


if __name__ == "__main__":
    checks = {
        "ready": ready,
        "seed": seed,
        "delete-after-dump": delete_after_dump,
        "verify-restored": verify_restored,
        "history": history,
        "conflict": conflict,
    }
    checks[sys.argv[1]]()

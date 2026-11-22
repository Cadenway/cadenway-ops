"""Drive the disposable versioned S3 bucket used by the backup integration test."""

import hashlib
import json
import os
import subprocess
import sys
from urllib.error import HTTPError
from urllib.request import urlopen

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

BUCKET = os.environ["STORAGE_S3_BUCKET"]
POST_DUMP_BYTES = b"uploaded after the dump"
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


def synthetic_references():
    return {
        os.environ["FIXTURE_ATTACHMENT_KEY"]: b"original attachment",
        os.environ["FIXTURE_INTAKE_KEY"]: b"original intake",
        f"profile-media/candidate/{os.environ['FIXTURE_PROFILE_ID']}": b"original avatar",
    }


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


def seed_attachment(attachment, data):
    organization_prefix = attachment.rsplit("/", 1)[0]
    staging = f"{organization_prefix}/018b6300-0000-7000-8000-000000000010"
    content_type = "text/plain"
    capability = S3.generate_presigned_post(
        BUCKET,
        staging,
        Fields={"Content-Type": content_type},
        Conditions=[
            {"Content-Type": content_type},
            ["content-length-range", 1, 25 * 1024 * 1024],
        ],
        ExpiresIn=60,
    )
    post = [
        "curl",
        "--silent",
        "--max-time",
        "20",
        "--output",
        "/dev/null",
        "--write-out",
        "%{http_code}",
    ]
    for name, value in capability["fields"].items():
        post.extend(("--form-string", f"{name}={value}"))
    upload = subprocess.run(
        [
            *post,
            "--form",
            f"file=@-;filename=attachment.txt;type={content_type}",
            capability["url"],
        ],
        input=data,
        capture_output=True,
        check=False,
    )
    assert upload.returncode == 0 and upload.stdout == b"204", (
        f"presigned attachment upload failed (curl {upload.returncode}, HTTP {upload.stdout.decode()})"
    )

    source = S3.head_object(Bucket=BUCKET, Key=staging)
    copy_input = {
        "Bucket": BUCKET,
        "Key": attachment,
        "CopySource": {"Bucket": BUCKET, "Key": staging},
        "CopySourceIfMatch": source["ETag"],
    }
    copy_model = S3.meta.service_model.operation_model("CopyObject")
    if "IfNoneMatch" in copy_model.input_shape.members:
        copy_input["IfNoneMatch"] = "*"
    else:
        # Older botocore models need the same header added before SigV4 signing.
        def add_copy_precondition(request, **_):
            request.headers["If-None-Match"] = "*"

        S3.meta.events.register("before-sign.s3.CopyObject", add_copy_precondition)

    copied = S3.copy_object(**copy_input)
    candidate = S3.head_object(Bucket=BUCKET, Key=attachment)
    assert candidate["VersionId"] == copied["VersionId"]
    assert candidate["ETag"] == copied["CopyObjectResult"]["ETag"]
    assert download(attachment) == data
    try:
        S3.copy_object(**copy_input)
    except ClientError as error:
        assert error.response["ResponseMetadata"]["HTTPStatusCode"] == 412
    else:
        raise AssertionError("conditional copy overwrote the existing attachment")


def create_bucket():
    S3.create_bucket(Bucket=BUCKET)
    S3.put_bucket_versioning(
        Bucket=BUCKET, VersioningConfiguration={"Status": "Enabled"}
    )
    assert S3.get_bucket_versioning(Bucket=BUCKET)["Status"] == "Enabled"


def seed():
    create_bucket()
    attachment = os.environ["FIXTURE_ATTACHMENT_KEY"]
    for key, data in synthetic_references().items():
        if key == attachment:
            seed_attachment(key, data)
        else:
            put(key, data)


def assert_hidden(key):
    try:
        download(key)
    except HTTPError as error:
        assert error.code == 404, f"unexpected download failure for {key}: {error.code}"
    else:
        raise AssertionError(
            f"current download still available for deleted object {key}"
        )


def delete_after_dump():
    history = {}
    for key, data in synthetic_references().items():
        version_id = S3.head_object(Bucket=BUCKET, Key=key)["VersionId"]
        delete = S3.delete_object(Bucket=BUCKET, Key=key)
        assert delete["DeleteMarker"], f"missing delete marker for {key}"
        assert_hidden(key)
        assert download(key, version_id) == data, f"historical download lost for {key}"
        history[key] = {"version": version_id, "marker": delete["VersionId"]}
    print(
        json.dumps(
            {
                "removed": history,
                "post_dump": put(os.environ["FIXTURE_POST_DUMP_KEY"], POST_DUMP_BYTES),
            }
        )
    )


def version_history(keys=()):
    entries = []
    for page in S3.get_paginator("list_object_versions").paginate(Bucket=BUCKET):
        for kind in ("Versions", "DeleteMarkers"):
            for item in page.get(kind, []):
                if not keys or item["Key"] in keys:
                    entries.append(
                        (item["Key"], kind, item["VersionId"], item["IsLatest"])
                    )
    return sorted(entries)


def verify_restored():
    before = json.load(sys.stdin)
    entries = version_history()
    for key, data in synthetic_references().items():
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
    post_dump = os.environ["FIXTURE_POST_DUMP_KEY"]
    assert (post_dump, "Versions", before["post_dump"], True) in entries, (
        "new version overwritten"
    )
    assert download(post_dump) == POST_DUMP_BYTES, "new upload changed"


def history(*keys):
    print(json.dumps(version_history(keys)))


def conflict():
    attachment = os.environ["FIXTURE_ATTACHMENT_KEY"]
    data = b"changed attachment!"
    assert len(data) == len(synthetic_references()[attachment])
    put(attachment, data)
    assert download(attachment) == data


def hide(*keys):
    for key in keys:
        previous = version_history((key,))
        assert any(kind == "Versions" for _, kind, _, _ in previous)
        if not any(
            kind == "DeleteMarkers" and latest for _, kind, _, latest in previous
        ):
            assert S3.delete_object(Bucket=BUCKET, Key=key)["DeleteMarker"]
        assert_hidden(key)
        assert any(
            kind == "DeleteMarkers" and latest
            for _, kind, _, latest in version_history((key,))
        )
    print("PASS both S3 downloads are hidden from current reads by delete markers")


def verify_recovered_versions(*keys):
    before = [tuple(entry) for entry in json.load(sys.stdin)]
    after = version_history(keys)
    for key in keys:
        previous = [entry for entry in before if entry[0] == key]
        recovered = [entry for entry in after if entry[0] == key]
        assert len(recovered) == len(previous) + 1, (
            f"expected one new version for {key}: before {previous}, after {recovered}"
        )
        assert all((*entry[:3], False) in recovered for entry in previous)
        assert (
            sum(kind == "Versions" and latest for _, kind, _, latest in recovered) == 1
        )
    print(
        "PASS restoration retained the previous versions and markers and added one active version per file"
    )


def digest(key):
    print(hashlib.sha256(download(key)).hexdigest())


if __name__ == "__main__":
    checks = {
        "ready": ready,
        "create-bucket": create_bucket,
        "seed": seed,
        "delete-after-dump": delete_after_dump,
        "verify-restored": verify_restored,
        "history": history,
        "conflict": conflict,
        "hide": hide,
        "verify-recovered-versions": verify_recovered_versions,
        "digest": digest,
    }
    checks[sys.argv[1]](*sys.argv[2:])

#!/usr/bin/env python3
"""Regression tests for the policy applied before Compose receives environment secrets."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


AGENT = Path(__file__).resolve().parents[1]
REPO = AGENT.parent


class ComposePolicyTest(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        base = Path(self.work.name)
        self.services = base / "services"
        self.services.mkdir()
        self.versions = base / "versions.env"
        self.versions.write_text("TASK_SERVICE_VERSION=1.2.3\n", encoding="utf-8")
        self.output = base / "validated"

    def run_policy(self, services=None, versions=None, require_digest=False):
        options = ["--require-digest"] if require_digest else []
        return subprocess.run(
            [
                sys.executable, "-E", "-P", str(AGENT / "compose-policy.py"),
                *options, str(services or self.services), str(versions or self.versions), str(self.output),
            ],
            capture_output=True, text=True, check=False,
        )

    def write_task(self, service_settings="", top_level=""):
        (self.services / "task-service.yaml").write_text(
            "services:\n"
            "  task-service:\n"
            "    image: ghcr.io/${GHCR_OWNER}/cadenway-task-service:${TASK_SERVICE_VERSION}\n"
            "    networks: [internal]\n"
            + service_settings
            + "networks:\n"
            "  internal: {}\n"
            + top_level,
            encoding="utf-8",
        )

    def assert_rejected(self, message, require_digest=False):
        result = self.run_policy(require_digest=require_digest)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)
        self.assertFalse(self.output.exists())

    def test_stages_canonical_source_with_owned_variables_and_escaped_dollars(self):
        self.write_task(
            "    environment: {DATABASE_URL: '${TASK_SERVICE_DATABASE_URL}'}\n"
            "    command: ['sh', '-c', 'printf %s $$DATABASE_URL']\n"
            "    configs: [{source: settings, target: /workspace/config.txt}]\n",
            "configs:\n  settings: {content: '${DOMAIN:-localhost}'}\n",
        )
        result = self.run_policy()
        self.assertEqual(result.returncode, 0, result.stderr)
        document = json.loads((self.output / "task-service.yaml").read_text(encoding="utf-8"))
        app = document["services"]["task-service"]
        self.assertEqual(app["environment"]["DATABASE_URL"], "${TASK_SERVICE_DATABASE_URL}")
        self.assertEqual(app["command"][2], "printf %s $$DATABASE_URL")

    def test_denies_cross_service_secrets_in_every_interpolated_position(self):
        fixtures = (
            ("    environment: {NOT_ALLOWED: '$IDENTITY_PASSWORD_PEPPER'}\n", ""),
            ("    command: ['${DOMAIN:-${IDENTITY_PASSWORD_PEPPER}}']\n", ""),
            ("    labels: ['a=${IDENTITY_PASSWORD_PEPPER}']\n", ""),
            ("", "configs:\n  settings: {content: '${IDENTITY_PASSWORD_PEPPER}'}\n"),
            ('    command: ["\\u0024{IDENTITY_PASSWORD_PEPPER}"]\n', ""),
        )
        for settings, model in fixtures:
            with self.subTest(settings=settings, model=model):
                self.write_task(settings, model)
                self.assert_rejected("variable IDENTITY_PASSWORD_PEPPER is outside the service grant")

    def test_denies_bypasses_around_normal_variable_resolution(self):
        fixtures = (
            ("    env_file: /etc/example/settings\n", ""),
            ("    environment: {IDENTITY_PASSWORD_PEPPER: null}\n", ""),
            ("    environment: [IDENTITY_PASSWORD_PEPPER]\n", ""),
            ("    volumes: ['/host:/inside']\n", ""),
            ("", "include: [/etc/example/compose.yaml]\n"),
            ("", "configs:\n  settings: {file: /etc/example/settings}\n"),
            ("", "configs:\n  settings: {environment: IDENTITY_PASSWORD_PEPPER}\n"),
            ("", "configs:\n  settings: &shared {content: 'value'}\n  copy: *shared\n"),
            ("    image: other\n", ""),
        )
        for settings, model in fixtures:
            with self.subTest(settings=settings, model=model):
                self.write_task(settings, model)
                self.assert_rejected("task-service.yaml")

    def test_denies_versions_file_as_an_environment_override(self):
        self.write_task()
        for line in (
            "IDENTITY_PASSWORD_PEPPER=another-value",
            "TASK_SERVICE_VERSION=${IDENTITY_PASSWORD_PEPPER}",
            "TASK_SERVICE_VERSION=another-version",
        ):
            with self.subTest(line=line):
                self.versions.write_text(f"TASK_SERVICE_VERSION=1.2.3\n{line}\n", encoding="utf-8")
                self.assert_rejected("literal image tag")

    def test_production_denies_a_mutable_tag(self):
        self.write_task()
        self.assert_rejected("production image TASK_SERVICE_VERSION needs tag@sha256", True)

    def test_production_uses_the_exact_approved_digest(self):
        self.write_task()
        pin = "1.2.3@sha256:" + "a" * 64
        self.versions.write_text(f"TASK_SERVICE_VERSION={pin}\n", encoding="utf-8")
        result = self.run_policy(require_digest=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.output / "task-service.yaml").read_text(encoding="utf-8"))
        self.assertEqual(
            manifest["services"]["task-service"]["image"],
            "ghcr.io/${GHCR_OWNER}/cadenway-task-service:" + pin,
        )

    def test_production_image_cannot_override_its_approval(self):
        self.write_task()
        pin = "1.2.3@sha256:" + "a" * 64
        self.versions.write_text(f"TASK_SERVICE_VERSION={pin}\n", encoding="utf-8")
        fixture = self.services / "task-service.yaml"
        model = fixture.read_text(encoding="utf-8").replace("${TASK_SERVICE_VERSION}", "1.2.3")
        fixture.write_text(model, encoding="utf-8")
        self.assert_rejected("production image must use the owning service's version pin", True)

    def test_other_service_cannot_request_a_private_redis_network(self):
        self.write_task()
        fixture = self.services / "task-service.yaml"
        model = fixture.read_text(encoding="utf-8").replace("[internal]", "[redis-api]")
        fixture.write_text(model + "  redis-api: {internal: true}\n", encoding="utf-8")
        self.assert_rejected("task-service.yaml")

    def test_other_service_cannot_claim_an_ingress_route(self):
        self.write_task(
            "    labels: ['traefik.http.routers.api-gateway-${ENVIRONMENT:-local}.rule"
            "=Host(`api.${DOMAIN}`)']\n"
        )
        self.assert_rejected("outside the service's route")

    def test_current_repository_manifest_stays_compatible(self):
        for name in ("staging", "prod"):
            with self.subTest(environment=name):
                env = REPO / "environments" / name
                if not env.is_dir():
                    self.skipTest("the full Ops checkout is only available outside the mounted CI harness")
                self.output = self.output.parent / name
                result = self.run_policy(env / "services", env / "versions.env")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    sorted(item.name for item in self.output.glob("*.yaml")),
                    sorted(item.name for item in (env / "services").glob("*.yaml")),
                )


if __name__ == "__main__":
    unittest.main()

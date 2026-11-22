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

    def run_policy(self, services=None, versions=None, require_digest=False, shared_host_quotas=False,
                   environment="local"):
        options = ["--environment", environment]
        if require_digest:
            options.append("--require-digest")
        if shared_host_quotas:
            options.append("--shared-host-quotas")
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

    def assert_rejected(self, message, **options):
        result = self.run_policy(**options)
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

    def test_hosted_releases_require_immutable_images(self):
        self.write_task()
        for env in ("staging", "prod"):
            with self.subTest(environment=env):
                self.assert_rejected("hosted image TASK_SERVICE_VERSION needs tag@sha256",
                                     require_digest=True, environment=env)

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
        self.assert_rejected("hosted image must use the owning service's version pin", require_digest=True)

    def test_shared_host_supplies_limits_without_a_deploy_section(self):
        self.write_task()
        result = self.run_policy(shared_host_quotas=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.output / "task-service.yaml").read_text(encoding="utf-8"))
        app = manifest["services"]["task-service"]
        self.assertEqual(app["deploy"], {
            "replicas": 1,
            "resources": {"limits": {"cpus": "0.50", "memory": "256m", "pids": 128}},
        })
        self.assertEqual(app["memswap_limit"], "256m")

    def test_shared_host_overwrites_source_limits_and_reservations(self):
        self.write_task(
            '    deploy:\n'
            '      resources:\n'
            '        limits: {cpus: "0.0", memory: 0, pids: -1}\n'
            '        reservations: {cpus: "1000", memory: 8g}\n'
        )
        result = self.run_policy(shared_host_quotas=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.output / "task-service.yaml").read_text(encoding="utf-8"))
        app = manifest["services"]["task-service"]
        self.assertEqual(app["deploy"]["resources"], {
            "limits": {"cpus": "0.50", "memory": "256m", "pids": 128},
        })

    def test_shared_host_rejects_owner_scale_and_competing_settings(self):
        for field, error in (
            ("deploy: {replicas: 2}", "owner must use one replica"),
            ("deploy: {replicas: true}", "owner must use one replica"),
            ("deploy: {replicas: '${TASK_SERVICE_RELAY_REPLICAS:-0}'}", "owner must use one replica"),
            ("scale: 3", "unsupported Compose mapping"),
            ("cpus: 0", "unsupported Compose mapping"),
            ("mem_limit: 0", "unsupported Compose mapping"),
            ("memswap_limit: -1", "unsupported Compose mapping"),
            ("pids_limit: -1", "unsupported Compose mapping"),
            ("deploy: {resources: {limits: {cgroup_parent: custom}}}", "unsupported Compose mapping"),
        ):
            with self.subTest(field=field):
                self.write_task(f"    {field}\n")
                self.assert_rejected(error, shared_host_quotas=True)

    def write_task_with_relay(self, replicas):
        self.write_task(
            "  task-service-relay:\n"
            "    image: ghcr.io/${GHCR_OWNER}/cadenway-task-service:${TASK_SERVICE_VERSION}\n"
            "    networks: [internal]\n"
            f"    deploy: {{replicas: {replicas}}}\n"
        )

    def test_shared_host_companion_preserves_its_bounded_replica_setting(self):
        self.write_task_with_relay("'${TASK_SERVICE_RELAY_REPLICAS:-0}'")
        result = self.run_policy(shared_host_quotas=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.output / "task-service.yaml").read_text(encoding="utf-8"))
        relay = manifest["services"]["task-service-relay"]
        self.assertEqual(relay["deploy"]["replicas"], "${TASK_SERVICE_RELAY_REPLICAS:-0}")
        self.assertEqual(relay["deploy"]["resources"], {
            "limits": {"cpus": "0.50", "memory": "256m", "pids": 128},
        })
        self.assertEqual(relay["memswap_limit"], "256m")

    def test_shared_host_rejects_unbounded_companion_replicas(self):
        for replicas in (3, -1, "false", "'${TASK_SERVICE_RELAY_REPLICAS:-3}'"):
            with self.subTest(replicas=replicas):
                self.write_task_with_relay(replicas)
                self.assert_rejected("companion must use zero to two replicas", shared_host_quotas=True)

    def test_shared_host_rejects_extra_workloads(self):
        self.write_task()
        extra = self.services / "extra.yaml"
        extra.write_text(
            "services:\n"
            "  extra: {image: fixture, networks: [internal]}\n"
            "networks: {internal: {}}\n",
            encoding="utf-8",
        )
        self.assert_rejected("no shared-host resource budget for this service", shared_host_quotas=True)

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

    def test_deployed_labels_are_a_static_mapping_for_the_assigned_environment(self):
        source = REPO / "environments" / "staging"
        if not source.is_dir():
            self.skipTest("the full Ops checkout is only available outside the mounted CI harness")
        result = self.run_policy(source / "services", source / "versions.env", environment="staging")
        self.assertEqual(result.returncode, 0, result.stderr)
        website = json.loads((self.output / "website.yaml").read_text(encoding="utf-8"))
        labels = website["services"]["website"]["labels"]
        self.assertTrue(all("$" not in key for key in labels))
        self.assertEqual(labels["traefik.http.routers.website-staging.rule"],
                         "Host(`${DOMAIN}`) || Host(`www.${DOMAIN}`)")

    def test_private_service_does_not_join_edge(self):
        self.write_task()
        fixture = self.services / "task-service.yaml"
        model = fixture.read_text(encoding="utf-8").replace("[internal]", "[internal, edge]")
        fixture.write_text(model, encoding="utf-8")
        self.assert_rejected("service networks must be declared bridge endpoints")

    def resolved_routing(self, model):
        return subprocess.run(
            [
                sys.executable, "-E", "-P", str(AGENT / "compose-policy.py"),
                "--environment", "staging", "--check-ingress", "staging.example.test", "https",
            ],
            input=json.dumps(model), capture_output=True, text=True, check=False,
        )

    def test_resolved_ingress_matches_the_host_and_network(self):
        model = {
            "networks": {"edge": {"name": "cadenway-edge-staging", "external": True}},
            "services": {"website": {"networks": {"edge": None}, "labels": {
                "traefik.enable": "true",
                "traefik.docker.network": "cadenway-edge-staging",
                "traefik.http.routers.website-staging.rule": "Host(`www.staging.example.test`)",
                "traefik.http.services.website-staging.loadbalancer.server.port": "8080",
                "traefik.http.middlewares.website-www-staging.redirectregex.replacement": "https://${1}",
            }}},
        }
        result = self.resolved_routing(model)
        self.assertEqual(result.returncode, 0, result.stderr)
        model["services"]["website"]["networks"] = {}
        result = self.resolved_routing(model)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("needs an explicit route, port and edge network", result.stderr)

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

    def test_current_repository_manifests_fit_shared_host_quotas(self):
        for name in ("staging", "prod"):
            with self.subTest(environment=name):
                env = REPO / "environments" / name
                if not env.is_dir():
                    self.skipTest("the full Ops checkout is only available outside the mounted CI harness")
                self.output = self.output.parent / name
                result = self.run_policy(env / "services", env / "versions.env", shared_host_quotas=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                for manifest in self.output.glob("*.yaml"):
                    owner = manifest.stem
                    app = json.loads(manifest.read_text(encoding="utf-8"))["services"][owner]
                    limits = (
                        {"cpus": "0.25", "memory": "64m", "pids": 64}
                        if owner in {"website", "webapp"}
                        else {"cpus": "0.50", "memory": "256m", "pids": 128}
                    )
                    self.assertEqual(app["deploy"], {"replicas": 1, "resources": {"limits": limits}})
                    self.assertEqual(app["memswap_limit"], limits["memory"])


if __name__ == "__main__":
    unittest.main()

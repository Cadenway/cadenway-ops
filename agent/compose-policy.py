#!/usr/bin/env python3
"""Validate service-owned Compose inputs before the agent supplies host settings."""

import argparse
import json
import re
import stat
import sys
from pathlib import Path

import yaml


# Explicit shared grants are part of the installed agent, outside the fetched repository.
PUBLIC = frozenset({"DOMAIN", "ENVIRONMENT", "GHCR_OWNER", "PUBLIC_SCHEME"})
NATS = {
    "automation-service": "AUTOMATION_NATS_PASSWORD",
    "billing-service": "BILLING_NATS_PASSWORD",
    "document-service": "DOCUMENT_NATS_PASSWORD",
    "identity-service": "IDENTITY_NATS_PASSWORD",
    "integration-service": "INTEGRATION_NATS_PASSWORD",
    "notification-service": "NOTIFICATION_NATS_PASSWORD",
    "organization-service": "ORGANIZATION_NATS_PASSWORD",
    "realtime-gateway": "REALTIME_GATEWAY_NATS_PASSWORD",
    "search-service": "SEARCH_NATS_PASSWORD",
    "storage-service": "STORAGE_NATS_PASSWORD",
    "task-service": "TASK_NATS_PASSWORD",
}
GRANTS = {
    "api-gateway": {
        "AUTOMATION_SERVICE_URL", "BILLING_SERVICE_URL", "DOCUMENT_SERVICE_URL",
        "IDENTITY_SERVICE_URL", "INTEGRATION_SERVICE_URL", "NOTIFICATION_SERVICE_URL",
        "ORGANIZATION_SERVICE_URL", "SEARCH_SERVICE_URL", "STORAGE_SERVICE_URL",
        "TASK_SERVICE_URL", "REDIS_URL", "API_GATEWAY_REDIS_URL",
        "API_GATEWAY_INTERNAL_TOKEN_PRIVATE_JWK",
    },
    "automation-service": {
        "AUTOMATION_COMMENT_AND_NOTIFICATION_ACTIONS_ENABLED", "AUTOMATION_CURSOR_SIGNING_KEY",
        "AUTOMATION_TASK_TRIGGERS_ENABLED",
        "AUTOMATION_SERVICE_INTERNAL_TOKEN_PRIVATE_JWK", "NOTIFICATION_SERVICE_URL",
        "TASK_SERVICE_URL",
    },
    "billing-service": {
        "BILLING_ORGANIZATION_SERVICE_URL", "BILLING_SERVICE_INTERNAL_TOKEN_PRIVATE_JWK",
        "BILLING_STORAGE_SERVICE_URL", "BILLING_USAGE_ENABLED",
        "ORGANIZATION_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS", "STORAGE_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS",
    },
    "document-service": {
        "DOCUMENT_ACCESS_MODE", "DOCUMENT_SEARCH_PROJECTION_CURSOR_SECRET",
        "DOCUMENT_SERVICE_INTERNAL_TOKEN_PRIVATE_JWK",
        "DOCUMENT_TASK_SERVICE_URL", "SEARCH_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS",
    },
    "identity-service": {
        "IDENTITY_AUTHENTICATION_COUNTER_RETENTION_ENABLED", "IDENTITY_PASSWORD_PEPPER",
        "IDENTITY_SERVICE_INTERNAL_TOKEN_PRIVATE_JWK",
        "NOTIFICATION_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS",
        "ORGANIZATION_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS", "ORGANIZATION_SERVICE_URL",
        "REALTIME_GATEWAY_INTERNAL_TOKEN_PUBLIC_JWKS",
    },
    "integration-service": {
        "GIT_LINK_EVENTS_ENABLED", "GIT_LINK_PURGE_ENABLED", "GIT_WEBHOOK_RECEIVERS",
        "INTEGRATION_SERVICE_INTERNAL_TOKEN_PRIVATE_JWK", "TASK_SERVICE_URL",
    },
    "notification-service": {
        "AUTOMATION_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS", "MAIL_FROM",
        "NOTIFICATION_IDENTITY_SERVICE_URL", "NOTIFICATION_ORGANIZATION_SERVICE_URL",
        "NOTIFICATION_SERVICE_INTERNAL_TOKEN_PRIVATE_JWK", "NOTIFICATION_TASK_SERVICE_URL",
        "NOTIFICATION_SERVICE_PROCESS_ROLE", "NOTIFICATION_SERVICE_WORKER_REPLICAS",
        "SITE_CONTACT_SUPPORT_ADDRESS", "SMTP_HOST", "SMTP_PASSWORD", "SMTP_PORT", "SMTP_USER",
    },
    "organization-service": {
        "BILLING_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS", "NOTIFICATION_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS",
        "IDENTITY_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS", "IDENTITY_SERVICE_URL",
        "ORGANIZATION_BILLING_AUTHORITY_CURSOR_SECRET", "ORGANIZATION_SEARCH_PROJECTION_CURSOR_SECRET",
        "ORGANIZATION_SEAT_ENTITLEMENT_EVENTS_ENABLED", "ORGANIZATION_SEAT_QUOTA_ENABLED",
        "ORGANIZATION_SERVICE_INTERNAL_TOKEN_PRIVATE_JWK", "TASK_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS",
        "REALTIME_GATEWAY_INTERNAL_TOKEN_PUBLIC_JWKS", "SEARCH_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS",
    },
    "realtime-gateway": {
        "IDENTITY_SERVICE_URL", "ORGANIZATION_SERVICE_URL",
        "REALTIME_GATEWAY_INTERNAL_TOKEN_PRIVATE_JWK", "REALTIME_GIT_RELAYS_ENABLED",
        "REALTIME_PAGED_RECIPIENTS_ENABLED",
        "TASK_SERVICE_URL", "REDIS_URL", "REALTIME_GATEWAY_REDIS_URL",
    },
    "search-service": {
        "DOCUMENT_SERVICE_URL", "MEILI_URL", "ORGANIZATION_SERVICE_URL",
        "SEARCH_SERVICE_MEILI_API_KEY",
        "SEARCH_SERVICE_INTERNAL_TOKEN_PRIVATE_JWK", "SEARCH_SERVICE_PALETTE_CURSOR_SECRET",
        "STORAGE_SERVICE_URL", "TASK_SERVICE_URL",
    },
    "storage-service": {
        "BILLING_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS", "SEARCH_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS",
        "STORAGE_BILLING_ENTITLEMENTS_ENABLED", "STORAGE_BILLING_PROJECTION_CURSOR_SECRET",
        "STORAGE_BYTE_QUOTA_ENABLED", "STORAGE_SEARCH_PROJECTION_CURSOR_SECRET",
        "STORAGE_S3_ACCESS_KEY_ID", "STORAGE_S3_BUCKET", "STORAGE_S3_ENDPOINT",
        "STORAGE_S3_FORCE_PATH_STYLE", "STORAGE_S3_PUBLIC_ENDPOINT", "STORAGE_S3_REGION",
        "STORAGE_S3_SECRET_ACCESS_KEY", "STORAGE_S3_ERASE_TRANSIENT_VERSIONS", "STORAGE_UPLOAD_RECEIPT_KEYS",
    },
    "task-service": {
        "AUTOMATION_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS", "DOCUMENT_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS",
        "INTEGRATION_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS", "ORGANIZATION_SERVICE_URL",
        "NOTIFICATION_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS", "SEARCH_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS",
        "REALTIME_GATEWAY_INTERNAL_TOKEN_PUBLIC_JWKS", "TASK_SERVICE_INTERNAL_TOKEN_PRIVATE_JWK",
        "TASK_SEARCH_PROJECTION_CURSOR_SECRET", "TASK_SERVICE_TRASH_WRITES_ENABLED",
        "TASK_MEMBERSHIP_AUTHORITY_MODE",
        "TASK_SERVICE_OUTBOX_MODE", "TASK_SERVICE_RELAY_REPLICAS",
    },
}
COMPANIONS = {
    "notification-service": "notification-service-worker",
    "task-service": "task-service-relay",
}
COMPANION_REPLICAS = {
    "notification-service-worker": "${NOTIFICATION_SERVICE_WORKER_REPLICAS:-0}",
    "task-service-relay": "${TASK_SERVICE_RELAY_REPLICAS:-0}",
}
FRONTEND_SERVICES = frozenset({"webapp", "website"})
APP_FIELDS = {
    "command", "configs", "deploy", "entrypoint", "environment", "healthcheck",
    "image", "init", "labels", "networks", "restart", "stop_grace_period",
}
NETWORKS = {
    "internal": ({},),
    "edge": ({"name": "cadenway-edge-${ENVIRONMENT:-local}", "external": True},),
}
PRIVATE_NETWORKS = {"api-gateway": "redis-api", "realtime-gateway": "redis-realtime"}
INGRESS = {
    "api-gateway": ("3000", {"Host(`api.${DOMAIN}`)"}),
    "realtime-gateway": ("3001", {"Host(`realtime.${DOMAIN}`)"}),
    "webapp": ("8080", {"Host(`app.${DOMAIN}`)"}),
    "website": (
        "8080",
        {"Host(`www.${DOMAIN}`)", "Host(`${DOMAIN}`) || Host(`www.${DOMAIN}`)"},
    ),
}
OWNER_NAME = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
CONFIG_NAME = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*")
ENV_NAME = re.compile(r"[a-zA-Z_][a-zA-Z0-9_]*")
TAG = re.compile(r"[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}")
PINNED_TAG = re.compile(TAG.pattern + r"@sha256:[0-9a-f]{64}")
REFERENCE = re.compile(r"\$\$|\$\{?([a-zA-Z_][a-zA-Z0-9_]*)")
ENVIRONMENT_REFERENCE = "${ENVIRONMENT:-local}"
DOMAIN = re.compile(r"[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?)*")
MAX_MANIFEST_BYTES = 64 * 1024


class PolicyError(Exception):
    """A source does not fit the installed deployment policy."""


class ManifestLoader(yaml.SafeLoader):
    """Use Compose-like booleans and refuse ambiguous mapping keys."""

    yaml_implicit_resolvers = {
        initial: [item for item in resolvers if item[0] != "tag:yaml.org,2002:bool"]
        for initial, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
    }

    def construct_mapping(self, node, deep=False):
        result = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            if not isinstance(key, str) or key in result:
                raise PolicyError("mapping keys must be unique strings")
            result[key] = self.construct_object(value_node, deep=deep)
        return result


ManifestLoader.add_implicit_resolver(
    "tag:yaml.org,2002:bool", re.compile(r"^(?:true|false)$", re.IGNORECASE), list("tTfF")
)


def mapping(value, fields=None):
    if not isinstance(value, dict) or (fields is not None and value.keys() - fields):
        raise PolicyError("unsupported Compose mapping")
    return value


def prefix(owner):
    return owner.upper().replace("-", "_")


def allowed_variables(owner):
    owner_prefix = prefix(owner)
    allowed = PUBLIC | GRANTS.get(owner, set()) | {
        f"{owner_prefix}_VERSION",
        f"{owner_prefix}_DATABASE_URL",
        # Old manifests can still carry their own migrator URL through a rollback.
        f"{owner_prefix}_MIGRATION_DATABASE_URL",
    }
    if owner in NATS:
        allowed |= {"NATS_URL", NATS[owner], "API_GATEWAY_INTERNAL_TOKEN_PUBLIC_JWKS"}
    return allowed


def check_references(value, allowed):
    if isinstance(value, dict):
        for key, item in value.items():
            if "$" in key:
                raise PolicyError("mapping keys must be static")
            check_references(item, allowed)
    elif isinstance(value, list):
        for item in value:
            check_references(item, allowed)
    elif isinstance(value, str):
        for name in REFERENCE.findall(value):
            if name and name not in allowed:
                raise PolicyError(f"variable {name} is outside the service grant")


def owned_ingress_labels(service):
    if service not in INGRESS:
        return {}
    env_ref = ENVIRONMENT_REFERENCE
    approved = {
        "traefik.enable": {"true", "false"},
        "traefik.docker.network": {f"cadenway-edge-{env_ref}"},
    }
    port, hosts = INGRESS[service]
    route = f"{service}-{env_ref}"
    approved[f"traefik.http.routers.{route}.rule"] = hosts
    approved[f"traefik.http.services.{route}.loadbalancer.server.port"] = {port}
    if service == "realtime-gateway":
        sticky = f"traefik.http.services.{route}.loadbalancer.sticky.cookie"
        approved[f"{sticky}.name"] = {"cadenway_realtime_route"}
        approved[f"{sticky}.secure"] = {"true"}
        approved[f"{sticky}.httponly"] = {"true"}
        approved[f"{sticky}.samesite"] = {"lax"}
    if service == "website":
        redirect = f"website-www-{env_ref}"
        approved[f"traefik.http.routers.{route}.middlewares"] = {redirect}
        approved[f"traefik.http.middlewares.{redirect}.redirectregex.regex"] = {
            r"^https?://www\.(.+)"
        }
        approved[f"traefik.http.middlewares.{redirect}.redirectregex.replacement"] = {
            "${PUBLIC_SCHEME:-https}://$${1}"
        }
        approved[f"traefik.http.middlewares.{redirect}.redirectregex.permanent"] = {"true"}
    return {key.lower(): values for key, values in approved.items()}


def canonical_labels(service, labels, environment):
    """Accept exact route templates and give Compose only static label names."""
    approved = owned_ingress_labels(service)
    if isinstance(labels, list):
        if not all(isinstance(label, str) and "=" in label for label in labels):
            raise PolicyError("invalid label mapping")
        labels = [label.split("=", 1) for label in labels]
    else:
        labels = mapping(labels).items()
    seen = set()
    canonical = {}
    for key, value in labels:
        match = key.lower()
        if match.startswith("traefik."):
            if not isinstance(value, str) or value not in approved.get(match, ()):
                raise PolicyError("an ingress label is outside the service's route")
            key = match.replace(ENVIRONMENT_REFERENCE.lower(), environment)
        elif not key or "$" in key:
            raise PolicyError("non-ingress label names must be static")
        if key.lower() in seen:
            raise PolicyError("label names must be unique")
        seen.add(key.lower())
        canonical[key] = value
    return canonical


def validate_application(service, app, configs, granted_networks, environment):
    mapping(app, APP_FIELDS)
    if not isinstance(app.get("image"), str):
        raise PolicyError("an application image is required")
    for name, value in mapping(app.get("environment", {})).items():
        if not ENV_NAME.fullmatch(name) or value is None:
            raise PolicyError("container environment needs explicit values")
    networks = app.get("networks")
    if not isinstance(networks, list) or not networks or not all(
        isinstance(name, str) and name in granted_networks for name in networks
    ):
        raise PolicyError("service networks must be declared bridge endpoints")
    if "edge" in networks and service not in INGRESS:
        raise PolicyError("only public services may join the edge network")
    deployment = mapping(app.get("deploy", {}), {"replicas", "resources"})
    for settings in mapping(deployment.get("resources", {}), {"limits", "reservations"}).values():
        mapping(settings, {"cpus", "memory", "pids"})
    if "labels" in app:
        app["labels"] = canonical_labels(service, app["labels"], environment)
    mounts = app.get("configs", [])
    if not isinstance(mounts, list):
        raise PolicyError("invalid config mounts")
    for mount in mounts:
        source = mount if isinstance(mount, str) else mapping(
            mount, {"source", "target", "uid", "gid", "mode"}
        ).get("source")
        if not isinstance(source, str) or source not in configs:
            raise PolicyError("a config mount must name a local inline config")


def apply_shared_host_quotas(document, owner):
    """Keep the application resource budget in the installed policy."""
    if owner not in GRANTS and owner not in FRONTEND_SERVICES:
        raise PolicyError("no shared-host resource budget for this service")
    # A file may only name its owner and the listed companion. The owner can have one
    # replica and each companion at most two. The rollout can overlap two generations.
    limits = (
        {"cpus": "0.25", "memory": "64m", "pids": 64}
        if owner in FRONTEND_SERVICES
        else {"cpus": "0.50", "memory": "256m", "pids": 128}
    )
    for name, app in document["services"].items():
        replicas = app.get("deploy", {}).get("replicas")
        if name == owner:
            if replicas is not None and not (type(replicas) is int and replicas == 1):
                raise PolicyError("shared-host owner must use one replica")
            replicas = 1
        elif not (
            (type(replicas) is int and 0 <= replicas <= 2)
            or replicas == COMPANION_REPLICAS[name]
        ):
            raise PolicyError("shared-host companion must use zero to two replicas")
        # Drop publisher-selected limits and reservations. The trusted replica reference
        # is checked again once Compose resolves the environment.
        app["deploy"] = {"replicas": replicas, "resources": {"limits": limits}}
        app["memswap_limit"] = limits["memory"]


def read_input(path):
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_MANIFEST_BYTES:
        raise PolicyError("input must be a small regular file")
    return path.read_text(encoding="utf-8")


def read_manifest(path, owner, environment):
    source = read_input(path)
    if any(
        isinstance(token, (yaml.AliasToken, yaml.AnchorToken, yaml.TagToken))
        for token in yaml.scan(source, Loader=ManifestLoader)
    ):
        raise PolicyError("Compose aliases, anchors and explicit tags are unavailable")
    document = mapping(yaml.load(source, Loader=ManifestLoader), {"services", "configs", "networks"})
    apps = mapping(document.get("services"), {owner, COMPANIONS.get(owner)})
    if owner not in apps:
        raise PolicyError("manifest must declare its owning service")
    configs = mapping(document.get("configs", {}))
    for name, config in configs.items():
        if not CONFIG_NAME.fullmatch(name) or not isinstance(
            mapping(config, {"content"}).get("content"), str
        ):
            raise PolicyError("only local inline configs are allowed")
    granted_networks = {name: options for name, options in NETWORKS.items()
                        if name != "edge" or owner in INGRESS}
    if owner in PRIVATE_NETWORKS:
        granted_networks[PRIVATE_NETWORKS[owner]] = ({"internal": True},)
    for name, network in mapping(document.get("networks", {}), granted_networks.keys()).items():
        if network not in granted_networks[name]:
            raise PolicyError("network cannot select a different host resource")
    for service, app in apps.items():
        validate_application(service, app, configs, granted_networks, environment)
    check_references(document, allowed_variables(owner))
    return document


def validate_versions(path, owners, require_digest):
    known = {f"{prefix(owner)}_VERSION" for owner in owners}
    versions = {}
    for line in read_input(path).splitlines():
        if not line or line.startswith("#"):
            continue
        name, separator, value = line.partition("=")
        if (
            not separator
            or name not in known
            or name in versions
            or (value and not (TAG.fullmatch(value) or PINNED_TAG.fullmatch(value)))
        ):
            raise PolicyError("versions.env only accepts each declared service's literal image tag")
        if require_digest and value and not PINNED_TAG.fullmatch(value):
            raise PolicyError(f"versions.env hosted image {name} needs tag@sha256:<digest>")
        versions[name] = value
    return versions


def pin_hosted_images(document, owner, versions):
    variable = f"{prefix(owner)}_VERSION"
    registry = f"ghcr.io/${{GHCR_OWNER}}/cadenway-{owner}:"
    expected = registry + f"${{{variable}}}"
    for app in document["services"].values():
        if app["image"] != expected:
            raise PolicyError("hosted image must use the owning service's version pin")
        # Insert the approved pin itself so Compose interpolation cannot substitute a tag
        # from the host process or another dotenv file.
        app["image"] = registry + versions.get(variable, "")


def stage_definitions(directory, version_file, destination, require_digest, shared_host_quotas,
                      environment):
    if directory.is_symlink() or not directory.is_dir():
        raise PolicyError("service definitions must be a real directory")
    manifests = {}
    config_names = set()
    paths = sorted(directory.glob("*.yaml"))
    if not paths:
        raise PolicyError("no service manifests found")
    if any(not OWNER_NAME.fullmatch(path.stem) for path in paths):
        raise PolicyError("invalid service manifest name")
    versions = validate_versions(version_file, (path.stem for path in paths), require_digest)
    for path in paths:
        owner = path.stem
        try:
            document = read_manifest(path, owner, environment)
            if shared_host_quotas:
                apply_shared_host_quotas(document, owner)
            if require_digest:
                pin_hosted_images(document, owner, versions)
            names = set(document.get("configs", {}))
            if names & config_names:
                raise PolicyError("inline config names must be unique in the project")
            config_names |= names
            # Compose consumes this canonical YAML-compatible JSON. No alternate YAML parser
            # interpretation can introduce fields, imports, or references after validation.
            manifests[path.name] = json.dumps(document, allow_nan=False)
        except PolicyError as error:
            raise PolicyError(f"{path.name}: {error}") from error
        except (OSError, ValueError, yaml.YAMLError, RecursionError) as error:
            raise PolicyError(f"{path.name}: unreadable or invalid manifest") from error
    destination.mkdir(mode=0o700)
    for name, document in manifests.items():
        (destination / name).write_text(f"{document}\n", encoding="utf-8")


def validate_resolved_ingress(model, environment, domain, scheme):
    """Check Compose's actual labels and networks against the host's public settings."""
    if not OWNER_NAME.fullmatch(environment) or not DOMAIN.fullmatch(domain) or scheme not in {"http", "https"}:
        raise PolicyError("invalid public routing settings")
    edge_name = f"cadenway-edge-{environment}"
    networks = mapping(model.get("networks", {}))
    if "edge" in networks:
        edge = mapping(networks["edge"])
        if edge.get("name") != edge_name or edge.get("external") is not True:
            raise PolicyError("the resolved edge network is outside the environment")

    def resolved_values(values):
        formats = set()
        for value in values:
            resolved = (value.replace(ENVIRONMENT_REFERENCE, environment).replace("${DOMAIN}", domain)
                        .replace("${PUBLIC_SCHEME:-https}", scheme))
            # Compose's normalized model may preserve the dollar escape for later YAML reuse.
            formats.update((resolved, resolved.replace("$$", "$")))
        return formats

    for service, app in mapping(model.get("services")).items():
        active_networks = mapping(app.get("networks", {}))
        actual_networks = {mapping(networks[name]).get("name", "") for name in active_networks}
        edge_networks = {name for name in actual_networks if name.startswith("cadenway-edge-")}
        if edge_networks - {edge_name}:
            raise PolicyError("a service joins another environment's edge network")
        joins_edge = edge_name in edge_networks
        labels = {key.lower(): value for key, value in mapping(app.get("labels", {})).items()
                  if key.lower().startswith("traefik.")}
        approved = {key.replace(ENVIRONMENT_REFERENCE.lower(), environment):
                    resolved_values(values)
                    for key, values in owned_ingress_labels(service).items()}
        if joins_edge and service not in INGRESS:
            raise PolicyError("a resolved private service joins the edge network")
        if any(value not in approved.get(key, ()) for key, value in labels.items()):
            raise PolicyError("resolved labels are outside the service's route")
        if labels.get("traefik.enable") == "true":
            router = f"traefik.http.routers.{service}-{environment}.rule"
            port = f"traefik.http.services.{service}-{environment}.loadbalancer.server.port"
            if not joins_edge or labels.get("traefik.docker.network") != edge_name or not (
                router in labels and port in labels
            ):
                raise PolicyError("a public service needs an explicit route, port and edge network")


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("directory", type=Path, nargs="?")
    cli.add_argument("versions", type=Path, nargs="?")
    cli.add_argument("destination", type=Path, nargs="?")
    cli.add_argument("--environment", default="local")
    cli.add_argument("--check-ingress", nargs=2, metavar=("DOMAIN", "SCHEME"))
    cli.add_argument("--require-digest", action="store_true")
    cli.add_argument("--shared-host-quotas", action="store_true")
    args = cli.parse_args()
    if not OWNER_NAME.fullmatch(args.environment):
        cli.error("invalid environment name")
    try:
        if args.check_ingress is not None:
            validate_resolved_ingress(json.load(sys.stdin), args.environment, *args.check_ingress)
        else:
            if args.directory is None or args.versions is None or args.destination is None:
                cli.error("staging requires directory, versions and destination")
            stage_definitions(
                args.directory, args.versions, args.destination, args.require_digest,
                args.shared_host_quotas, args.environment,
            )
    except PolicyError as error:
        cli.exit(1, f"Compose policy: {error}\n")
    except (OSError, ValueError, TypeError, KeyError):
        cli.exit(1, "Compose policy: input or temporary directory rejected\n")


if __name__ == "__main__":
    main()

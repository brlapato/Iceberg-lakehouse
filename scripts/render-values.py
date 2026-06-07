#!/usr/bin/env python3
"""
Reads config/lakehouse-config.yaml and propagates values into component
values files. Run via 'make keycloak-config' after editing the ConfigMap.

What gets patched:
  config/lakehouse-config.yaml  — KEYCLOAK_ISSUER_URL and KEYCLOAK_JWKS_URL
                                   (derived from KEYCLOAK_URL + KEYCLOAK_REALM)
  openmetadata/values.yaml      — authentication.publicKeys, authentication.authority
  trino/values.yaml             — Ranger XML blocks (ranger-security.xml in
                                   coordinator and worker additionalConfigFiles)
  ranger/values.yaml            — policymgrUrl

Trino catalog properties and additionalConfigProperties use ${ENV:VAR} substitution
at runtime. Non-secret values are injected via individual configMapKeyRef entries
in the top-level env: section of trino/values.yaml — no render-time patching needed.
"""
import re
import sys
import yaml
from pathlib import Path

ROOT = Path(__file__).parent.parent


def load_config() -> dict:
    path = ROOT / "config" / "lakehouse-config.yaml"
    with open(path) as f:
        manifest = yaml.safe_load(f)
    return manifest["data"]


def patch_file(path: Path, replacements: list[tuple[str, str]], label: str = ""):
    content = path.read_text()
    for pattern, replacement in replacements:
        content = re.sub(pattern, replacement, content)
    path.write_text(content)
    print(f"[render-values] Patched {path.relative_to(ROOT)}{f'  ({label})' if label else ''}")


def update_configmap_derived_fields(issuer: str, jwks_url: str):
    """Write computed KEYCLOAK_ISSUER_URL and KEYCLOAK_JWKS_URL back into the ConfigMap file."""
    path = ROOT / "config" / "lakehouse-config.yaml"
    patch_file(
        path,
        [
            (
                r'(  KEYCLOAK_ISSUER_URL: ")[^"]*(")',
                rf'\g<1>{issuer}\g<2>',
            ),
            (
                r'(  KEYCLOAK_JWKS_URL: ")[^"]*(")',
                rf'\g<1>{jwks_url}\g<2>',
            ),
        ],
        label="derived Keycloak URLs",
    )


def patch_openmetadata(issuer: str, jwks_url: str):
    patch_file(
        ROOT / "openmetadata" / "values.yaml",
        [
            (
                r'(- )https?://[^\n]+/protocol/openid-connect/certs',
                rf'\g<1>{jwks_url}',
            ),
            (
                r'(authority: )https?://[^\n]+',
                rf'\g<1>{issuer}',
            ),
        ],
        label="OIDC authority + JWKS URL",
    )


def patch_trino_ranger_xml(ranger_url: str, ranger_service: str):
    """Patch the Ranger XML blocks in trino/values.yaml (XML doesn't support ${ENV:...})."""
    patch_file(
        ROOT / "trino" / "values.yaml",
        [
            (
                r'(<name>ranger\.plugin\.trino\.policy\.rest\.url</name>\s*<value>)[^<]*(</value>)',
                rf'\g<1>{ranger_url}\g<2>',
            ),
            (
                r'(<name>ranger\.plugin\.trino\.service\.name</name>\s*<value>)[^<]*(</value>)',
                rf'\g<1>{ranger_service}\g<2>',
            ),
        ],
        label="Ranger XML policy URL + service name",
    )


def patch_ranger_values(ranger_url: str):
    patch_file(
        ROOT / "ranger" / "values.yaml",
        [
            (
                r'(policymgrUrl: ")[^"]*(")',
                rf'\g<1>{ranger_url}\g<2>',
            ),
        ],
        label="policymgrUrl",
    )


def main():
    data = load_config()

    keycloak_url = data["KEYCLOAK_URL"].rstrip("/")
    realm = data["KEYCLOAK_REALM"]
    ranger_url = data["RANGER_URL"].rstrip("/")
    ranger_service = data["RANGER_SERVICE_NAME"]

    issuer = f"{keycloak_url}/realms/{realm}"
    jwks_url = f"{keycloak_url}/realms/{realm}/protocol/openid-connect/certs"

    update_configmap_derived_fields(issuer, jwks_url)
    patch_openmetadata(issuer, jwks_url)
    patch_trino_ranger_xml(ranger_url, ranger_service)
    patch_ranger_values(ranger_url)

    print(f"[render-values] Keycloak issuer : {issuer}")
    print(f"[render-values] Ranger URL      : {ranger_url}")
    print(f"[render-values] Ranger service  : {ranger_service}")
    print("[render-values] Done. Run 'make config' to apply the ConfigMap to the cluster.")


if __name__ == "__main__":
    main()

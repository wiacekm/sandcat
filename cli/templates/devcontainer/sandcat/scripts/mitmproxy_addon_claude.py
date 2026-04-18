"""
Claude-focused mitmproxy addon: original network policy + secret substitution.
"""

import base64
import binascii
import json
import logging
import os
import re
import subprocess
import sys
from fnmatch import fnmatch

from mitmproxy import ctx, dns, http

_VALID_ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

SETTINGS_PATHS = [
    "/config/settings.json",
    "/config/project/settings.json",
    "/config/project/settings.local.json",
]
SANDCAT_ENV_PATH = "/home/mitmproxy/.mitmproxy/sandcat.env"
SANDCAT_SECRETS_PATH = "/home/mitmproxy/.mitmproxy/sandcat-secrets.json"

logger = logging.getLogger(__name__)


class SandcatAddon:
    def __init__(self):
        self.secrets: dict[str, dict] = {}
        self.network_rules: list[dict] = []
        self.env: dict[str, str] = {}
        self.debug_enabled = False

    def load(self, loader):
        layers = []
        for path in SETTINGS_PATHS:
            if os.path.isfile(path):
                with open(path) as f:
                    layers.append(json.load(f))

        if not layers:
            logger.info("No settings files found — addon disabled")
            return

        merged = self._merge_settings(layers)
        raw_debug = merged.get("env", {}).get(
            "SANDCAT_MITM_DEBUG", os.environ.get("SANDCAT_MITM_DEBUG", "")
        )
        self.debug_enabled = self._is_truthy(raw_debug)

        self._configure_op_token(merged.get("op_service_account_token"))
        self.env = merged["env"]
        self._load_secrets(merged["secrets"])
        self._load_network_rules(merged["network"])
        self._write_placeholders_env()
        self._write_secrets_json()

        ctx.log.info(
            f"Loaded {len(self.env)} env var(s) and {len(self.secrets)} secret(s), "
            f"wrote {SANDCAT_ENV_PATH} and {SANDCAT_SECRETS_PATH}"
        )

    @staticmethod
    def _is_truthy(value: str | bool | None) -> bool:
        if value is None:
            return False
        if isinstance(value, bool):
            return value
        return str(value).strip().lower() in {"1", "true", "yes", "on"}

    @staticmethod
    def _configure_op_token(token: str | None):
        if token and "OP_SERVICE_ACCOUNT_TOKEN" not in os.environ:
            os.environ["OP_SERVICE_ACCOUNT_TOKEN"] = token

    @staticmethod
    def _merge_settings(layers: list[dict]) -> dict:
        env: dict[str, str] = {}
        secrets: dict[str, dict] = {}
        network: list[dict] = []
        op_token: str | None = None

        for layer in layers:
            env.update(layer.get("env", {}))
            secrets.update(layer.get("secrets", {}))
            layer_token = layer.get("op_service_account_token")
            if layer_token:
                op_token = layer_token

        for layer in reversed(layers):
            network.extend(layer.get("network", []))

        return {
            "env": env,
            "secrets": secrets,
            "network": network,
            "op_service_account_token": op_token,
        }

    def _load_secrets(self, raw_secrets: dict):
        for name, entry in raw_secrets.items():
            placeholder = f"SANDCAT_PLACEHOLDER_{name}"
            try:
                value = self._resolve_secret_value(name, entry)
            except (RuntimeError, ValueError) as e:
                ctx.log.warn(str(e))
                print(f"WARNING: {e}", file=sys.stderr)
                value = ""
            self.secrets[name] = {
                "value": value,
                "hosts": entry.get("hosts", []),
                "placeholder": placeholder,
            }

    @staticmethod
    def _resolve_secret_value(name: str, entry: dict) -> str:
        has_value = "value" in entry
        has_op = "op" in entry
        if has_value and has_op:
            raise ValueError(f"Secret {name!r}: specify either 'value' or 'op', not both")
        if not has_value and not has_op:
            raise ValueError(f"Secret {name!r}: must specify either 'value' or 'op'")
        if has_value:
            return entry["value"]

        op_ref = entry["op"]
        if not op_ref.startswith("op://"):
            raise ValueError(f"Secret {name!r}: 'op' value must start with 'op://', got {op_ref!r}")

        try:
            result = subprocess.run(["op", "read", op_ref], capture_output=True, text=True, timeout=30)
        except FileNotFoundError:
            raise RuntimeError(
                f"Secret {name!r}: 'op' CLI not found. Install 1Password CLI to use op:// references."
            ) from None

        if result.returncode != 0:
            raise RuntimeError(f"Secret {name!r}: 'op read' failed: {result.stderr.strip()}")
        return result.stdout.strip()

    def _load_network_rules(self, raw_rules: list):
        self.network_rules = raw_rules
        ctx.log.info(f"Loaded {len(self.network_rules)} network rule(s)")

    def _find_matching_rule(self, method: str | None, host: str) -> dict | None:
        host = host.lower().rstrip(".")
        for rule in self.network_rules:
            if not fnmatch(host, rule["host"].lower()):
                continue
            rule_method = rule.get("method")
            if rule_method is not None and method is not None and rule_method.upper() != method.upper():
                continue
            return rule
        return None

    @staticmethod
    def _shell_escape(value: str) -> str:
        return (
            value.replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("$", "\\$")
            .replace("`", "\\`")
            .replace("\n", "\\n")
        )

    @staticmethod
    def _validate_env_name(name: str):
        if not _VALID_ENV_NAME.match(name):
            raise ValueError(f"Invalid env var name: {name!r}")

    def _write_placeholders_env(self):
        lines = []
        for name, value in self.env.items():
            self._validate_env_name(name)
            lines.append(f'export {name}="{self._shell_escape(value)}"')
        for name, entry in self.secrets.items():
            self._validate_env_name(name)
            lines.append(f'export {name}="{self._shell_escape(entry["placeholder"])}"')
        with open(SANDCAT_ENV_PATH, "w") as f:
            f.write("\n".join(lines) + "\n")

    def _write_secrets_json(self):
        data = {name: entry["value"] for name, entry in self.secrets.items()}
        with open(SANDCAT_SECRETS_PATH, "w") as f:
            json.dump(data, f)
        os.chmod(SANDCAT_SECRETS_PATH, 0o600)

    @staticmethod
    def _is_textual_content_type(content_type: str | None) -> bool:
        if not content_type:
            return False
        media_type = content_type.split(";", 1)[0].strip().lower()
        return (
            media_type.startswith("text/")
            or media_type
            in {
                "application/json",
                "application/x-www-form-urlencoded",
                "application/xml",
                "application/javascript",
                "application/graphql",
            }
            or media_type.endswith("+json")
            or media_type.endswith("+xml")
        )

    @staticmethod
    def _basic_auth_contains_placeholder(auth_header: str | None, placeholder: str) -> bool:
        if not auth_header or not auth_header.lower().startswith("basic "):
            return False
        encoded = auth_header.split(" ", 1)[1].strip()
        if not encoded:
            return False
        try:
            decoded = base64.b64decode(encoded).decode("utf-8")
        except (binascii.Error, UnicodeDecodeError, ValueError):
            return False
        return placeholder in decoded

    @staticmethod
    def _replace_placeholder_in_basic_auth(
        auth_header: str | None, placeholder: str, value: str
    ) -> tuple[str | None, bool]:
        if not auth_header or not auth_header.lower().startswith("basic "):
            return auth_header, False
        encoded = auth_header.split(" ", 1)[1].strip()
        if not encoded:
            return auth_header, False
        try:
            decoded = base64.b64decode(encoded).decode("utf-8")
        except (binascii.Error, UnicodeDecodeError, ValueError):
            return auth_header, False
        if placeholder not in decoded:
            return auth_header, False
        replaced = decoded.replace(placeholder, value)
        return f"Basic {base64.b64encode(replaced.encode('utf-8')).decode('ascii')}", True

    def _substitute_secrets(self, flow: http.HTTPFlow):
        host = flow.request.pretty_host.lower()
        for name, entry in self.secrets.items():
            placeholder = entry["placeholder"]
            value = entry["value"]
            allowed_hosts = entry["hosts"]
            auth_header = flow.request.headers.get("authorization", "")

            present = (
                placeholder in flow.request.url
                or placeholder in str(flow.request.headers)
                or self._basic_auth_contains_placeholder(auth_header, placeholder)
                or (
                    flow.request.content
                    and placeholder.encode() in flow.request.content
                )
            )
            if not present:
                continue

            if not any(fnmatch(host, pattern.lower()) for pattern in allowed_hosts):
                flow.response = http.Response.make(
                    403,
                    f"Blocked: secret {name!r} not allowed for host {host!r}\n".encode(),
                    {"Content-Type": "text/plain"},
                )
                ctx.log.warn(f"Blocked secret {name!r} leak to disallowed host {host!r}")
                return

            if placeholder in flow.request.url:
                flow.request.url = flow.request.url.replace(placeholder, value)

            for k, v in flow.request.headers.items():
                if placeholder in v:
                    flow.request.headers[k] = v.replace(placeholder, value)

            updated_auth, replaced_basic_auth = self._replace_placeholder_in_basic_auth(
                flow.request.headers.get("authorization", ""), placeholder, value
            )
            if replaced_basic_auth and updated_auth is not None:
                flow.request.headers["authorization"] = updated_auth

            if flow.request.content and placeholder.encode() in flow.request.content:
                content_type = flow.request.headers.get("content-type", "")
                if self._is_textual_content_type(content_type):
                    flow.request.content = flow.request.content.replace(
                        placeholder.encode(), value.encode()
                    )

    def request(self, flow: http.HTTPFlow):
        method = flow.request.method
        host = flow.request.pretty_host
        matching_rule = self._find_matching_rule(method, host)
        if matching_rule is None or matching_rule.get("action") != "allow":
            flow.response = http.Response.make(
                403,
                f"Blocked by network policy: {method} {host}\n".encode(),
                {"Content-Type": "text/plain"},
            )
            ctx.log.warn(f"Network deny: {method} {host}")
            return
        self._substitute_secrets(flow)

    def dns_request(self, flow: dns.DNSFlow):
        question = flow.request.question
        if question is None:
            flow.response = flow.request.fail(dns.response_codes.REFUSED)
            return
        host = question.name
        matching_rule = self._find_matching_rule(None, host)
        if matching_rule is None or matching_rule.get("action") != "allow":
            flow.response = flow.request.fail(dns.response_codes.REFUSED)
            ctx.log.warn(f"DNS deny: {host}")


addons = [SandcatAddon()]


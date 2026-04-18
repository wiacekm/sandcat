"""
Cursor-focused mitmproxy addon: network policy + secret substitution.

This variant keeps Cursor Connect streaming traffic opaque (no body mutation)
while still applying placeholder substitution in URL/headers/basic auth.
"""

import base64
import binascii
import hashlib
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

    def _debug(self, message: str):
        if self.debug_enabled:
            ctx.log.info(f"[sandcat-debug] {message}")

    @staticmethod
    def _auth_debug_summary(header: str | None) -> str:
        """Safe fingerprint for logs: no raw secrets; detects odd bytes (401 debugging)."""
        if not header:
            return "authorization=<missing>"

        h = header.strip()
        low = h.lower()
        if low.startswith("bearer "):
            tok = h[7:].strip()
            fp = hashlib.sha256(tok.encode("utf-8")).hexdigest()[:12]
            bad = [hex(ord(c)) for c in tok if ord(c) < 32 or ord(c) == 127]
            extra = f" ctrl_bytes={bad[:8]}" if bad else ""
            return f"bearer len={len(tok)} sha256_12={fp}{extra}"

        if low.startswith("basic "):
            raw = h[6:].strip()
            try:
                dec = base64.b64decode(raw).decode("utf-8")
            except (binascii.Error, UnicodeDecodeError, ValueError) as e:
                return f"basic decode_err={e!r}"
            fp = hashlib.sha256(dec.encode("utf-8")).hexdigest()[:12]
            bad = [hex(ord(c)) for c in dec if ord(c) < 32 and c not in "\t"]
            extra = f" ctrl_bytes={bad[:8]}" if bad else ""
            return f"basic decoded_len={len(dec)} sha256_12={fp}{extra}"

        return f"other len={len(h)}"

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
                "value": self._normalize_secret_value(value),
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
            return SandcatAddon._normalize_secret_value(entry["value"])

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
            stderr = result.stderr.strip()
            raise RuntimeError(f"Secret {name!r}: 'op read' failed: {stderr}")

        return SandcatAddon._normalize_secret_value(result.stdout.strip())

    @staticmethod
    def _normalize_secret_value(value: str) -> str:
        """Strip accidental whitespace/newlines from JSON or CLI output (common 401 cause)."""
        if value is None:
            return ""
        s = str(value).strip()
        # Strip UTF-8 BOM from pasted JSON / editor exports (invisible in most UIs).
        return s.lstrip("\ufeff")

    @staticmethod
    def _normalize_authorization_header_value(v: str) -> str:
        """Trim token after substitution; keep the client's Bearer scheme spelling (RFC 7235 is case-insensitive, some stacks are picky)."""
        v = v.strip()
        if len(v) >= 7 and v[:7].lower() == "bearer ":
            token = v[7:].strip()
            scheme = v[:6]  # preserve e.g. Bearer / bearer / BEARER
            return f"{scheme} {token}"
        return v

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

    def _is_request_allowed(self, method: str | None, host: str) -> bool:
        rule = self._find_matching_rule(method, host)
        if rule is None:
            return False
        return rule["action"] == "allow"

    @staticmethod
    def _is_cursor_host(host: str) -> bool:
        host = host.lower().rstrip(".")
        return (
            host == "cursor.sh"
            or host == "cursor.com"
            or host.endswith(".cursor.sh")
            or host.endswith(".cursor.com")
        )

    def _is_cursor_streaming_request(self, flow: http.HTTPFlow) -> bool:
        host = flow.request.pretty_host.lower()
        if not self._is_cursor_host(host):
            return False

        path = flow.request.path
        if (
            path.startswith("/agent.v1.AgentService/Run")
            or path.startswith("/agent.v1.AgentService/RunSSE")
            or path.startswith("/aiserver.v1.RepositoryService/")
        ):
            return True

        content_type = flow.request.headers.get("content-type", "")
        return "application/connect+proto" in content_type.lower()

    @staticmethod
    def _prepare_cursor_streaming_request(flow: http.HTTPFlow):
        flow.request.headers["accept-encoding"] = "identity"
        flow.request.stream = True

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
        # Trim only outer CR/LF; avoids invisible line-ending damage from clients/editors.
        replaced = replaced.strip("\r\n")
        new_encoded = base64.b64encode(replaced.encode("utf-8")).decode("ascii")
        return f"Basic {new_encoded}", True

    def _substitute_secrets(self, flow: http.HTTPFlow):
        host = flow.request.pretty_host.lower()
        is_cursor_streaming = self._is_cursor_streaming_request(flow)
        pre_auth = (
            self._auth_debug_summary(flow.request.headers.get("authorization"))
            if self.debug_enabled
            else ""
        )

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
                    not is_cursor_streaming
                    and flow.request.content
                    and placeholder.encode("utf-8") in flow.request.content
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

            for k, v in list(flow.request.headers.items()):
                if placeholder in v:
                    new_v = v.replace(placeholder, value)
                    if k.lower() == "authorization":
                        new_v = self._normalize_authorization_header_value(new_v)
                    flow.request.headers[k] = new_v

            updated_auth, replaced_basic_auth = self._replace_placeholder_in_basic_auth(
                flow.request.headers.get("authorization", ""), placeholder, value
            )
            if replaced_basic_auth and updated_auth is not None:
                flow.request.headers["authorization"] = updated_auth

            if is_cursor_streaming:
                continue

            if flow.request.content and placeholder.encode("utf-8") in flow.request.content:
                content_type = flow.request.headers.get("content-type", "")
                if self._is_textual_content_type(content_type):
                    flow.request.content = flow.request.content.replace(
                        placeholder.encode("utf-8"), value.encode("utf-8")
                    )

        if self.debug_enabled:
            post_auth = self._auth_debug_summary(flow.request.headers.get("authorization"))
            self._debug(
                f"{flow.request.method} {flow.request.pretty_host}{flow.request.path} "
                f"streaming={is_cursor_streaming} auth_pre={pre_auth} auth_post={post_auth}"
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

        if self._is_cursor_streaming_request(flow):
            self._prepare_cursor_streaming_request(flow)

        self._substitute_secrets(flow)

    def responseheaders(self, flow: http.HTTPFlow):
        if self._is_cursor_streaming_request(flow):
            flow.response.stream = True

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


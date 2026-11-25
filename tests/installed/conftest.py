"""Vault fixtures. A fresh install is sealed and uninitialized: `root_token` initializes it (one unseal key, which is
fine for a throwaway test VM and nowhere else) and unseals it, so the tests can use it. The key is kept in
.vm/vault-init.json so re-running the tests on the same install works."""
import json
import secrets
import time
from pathlib import Path

import pytest
import requests

STATE = Path(__file__).resolve().parents[2] / ".vm"

NODE_PORT = 30820


class Vault:
    """A thin client for Vault's HTTP API: returns the response so each test asserts on status codes itself."""

    def __init__(self, url, token=None):
        self.url, self.token = url, token

    def call(self, method, path, json_body=None, token=None):
        token = token or self.token
        headers = {"X-Vault-Token": token} if token else {}
        return requests.request(method, f"{self.url}/v1/{path}", json=json_body, headers=headers, timeout=10)

    def ok(self, method, path, json_body=None):
        """Call, and fail the test with Vault's own error message unless it succeeded."""
        response = self.call(method, path, json_body)
        assert response.ok, f"{method} {path}: {response.status_code} {response.text}"
        return response.json() if response.content else {}

    def enable(self, kind, path, engine_type, **options):
        """Enable an auth method or secrets engine unless it's already there (keeps reruns idempotent)."""
        listing = "sys/auth" if kind == "auth" else "sys/mounts"
        if f"{path}/" not in self.ok("GET", listing)["data"]:
            self.ok("POST", f"{listing}/{path}", {"type": engine_type, **options})


def wait_until(check, timeout, what):
    deadline = time.monotonic() + timeout
    while True:
        try:
            result = check()
            if result:
                return result
        except requests.RequestException:
            pass
        if time.monotonic() > deadline:
            pytest.fail(f"timed out after {timeout}s waiting for {what}")
        time.sleep(2)


@pytest.fixture(scope="session")
def vault_url(host_ip):
    return f"http://{host_ip}:{NODE_PORT}"


@pytest.fixture(scope="session")
def root_token(vault_url):
    vault = Vault(vault_url)
    status = wait_until(lambda: vault.call("GET", "sys/seal-status").json(), 120, "Vault's API to answer")
    init_file = STATE / "vault-init.json"
    if not status["initialized"]:
        response = vault.call("POST", "sys/init", {"secret_shares": 1, "secret_threshold": 1})
        assert response.ok, f"init: {response.status_code} {response.text}"
        init_file.write_text(response.text)
        init_file.chmod(0o600)
    elif not init_file.exists():
        pytest.exit("Vault is initialized but .vm/vault-init.json is gone: reinstall (uninstall, install)", 2)
    init = json.loads(init_file.read_text())
    if vault.call("GET", "sys/seal-status").json()["sealed"]:
        response = vault.call("POST", "sys/unseal", {"key": init["keys_base64"][0]})
        assert response.ok, f"unseal: {response.status_code} {response.text}"
    # /sys/health is 200 only when initialized, unsealed and active
    wait_until(lambda: vault.call("GET", "sys/health").status_code == 200, 60, "Vault to become active")
    return init["root_token"]


@pytest.fixture(scope="session")
def vault(vault_url, root_token):
    return Vault(vault_url, root_token)


@pytest.fixture(scope="session")
def app_secret(vault):
    """A KV v2 engine at secret/ with one secret, secret/app/config, and a policy that may only read under app/."""
    vault.enable("mounts", "secret", "kv", options={"version": "2"})
    password = secrets.token_urlsafe(16)
    vault.ok("POST", "secret/data/app/config", {"data": {"password": password}})
    vault.ok("PUT", "sys/policies/acl/app-read", {"policy": 'path "secret/data/app/*" { capabilities = ["read"] }'})
    return {"path": "secret/data/app/config", "password": password, "policy": "app-read"}

"""Shared fixtures: how the tests on the build machine reach the appliance VM (ssh, kubectl) and what was installed.

scripts/appliance.sh vm/install write these files into .vm/: host (ubuntu@<ip>), id_ed25519, kubeconfig.
"""
import json
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / ".vm"


def read_versions():
    versions = {}
    for line in (ROOT / "versions.env").read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            key, value = line.split("=", 1)
            versions[key] = value
    return versions


@pytest.fixture(scope="session")
def versions():
    return read_versions()


@pytest.fixture(scope="session")
def host():
    path = STATE / "host"
    if not path.exists():
        pytest.exit("no appliance VM: run scripts/appliance.sh vm and install first", returncode=2)
    return path.read_text().strip()


@pytest.fixture(scope="session")
def host_ip(host):
    return host.split("@", 1)[1]


@pytest.fixture(scope="session")
def ssh(host):
    """Run a shell command on the appliance; returns the CompletedProcess (check=False leaves the exit code to you)."""
    def run(command, check=True, timeout=120):
        return subprocess.run(
            ["ssh", "-i", str(STATE / "id_ed25519"), "-o", "StrictHostKeyChecking=no",
             "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10",
             host, command],
            capture_output=True, text=True, check=check, timeout=timeout)
    return run


@pytest.fixture(scope="session")
def kubectl():
    """Run kubectl against the appliance's k3s from the build machine."""
    def run(*args, check=True, stdin=None, timeout=180):
        return subprocess.run(
            ["kubectl", "--kubeconfig", str(STATE / "kubeconfig"), *args],
            capture_output=True, text=True, check=check, input=stdin, timeout=timeout)
    return run


@pytest.fixture(scope="session")
def kubectl_json(kubectl):
    def run(*args):
        return json.loads(kubectl(*args, "-o", "json").stdout)
    return run

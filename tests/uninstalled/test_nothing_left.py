"""After uninstall.sh: is the appliance back to how it was before the package, with k3s itself still healthy?

An uninstall that leaves a webhook, a cluster role or a volume behind breaks the next install or quietly keeps data
that should be gone (Vault's storage holds secrets), so each kind of leftover gets its own check.
"""
import pytest


def names(kubectl, *args):
    return [n for n in kubectl("get", *args, "-o", "name").stdout.split() if "vault" in n or "demo" in n]


def test_namespaces_are_gone(kubectl):
    assert names(kubectl, "namespaces") == []


def test_no_cluster_wide_leftovers(kubectl):
    """Helm releases also create objects outside their namespace; those are the ones uninstalls tend to miss."""
    for kind in ("mutatingwebhookconfigurations", "clusterroles", "clusterrolebindings"):
        assert names(kubectl, kind) == [], f"{kind} left behind"


def test_no_volume_left_with_vault_data(kubectl, ssh):
    assert kubectl("get", "pv", "-o", "name").stdout.strip() == "", "a PersistentVolume is left"
    # local-path keeps volumes in this folder on the node; Vault's data folder would be named after its claim
    leftovers = ssh("sudo ls /var/lib/rancher/k3s/storage", check=False).stdout.split()
    assert [d for d in leftovers if "vault" in d] == []


def test_images_removed_from_containerd(ssh):
    images = ssh("sudo k3s crictl images -o json").stdout
    assert "hashicorp/" not in images


@pytest.mark.parametrize("path", ["/usr/local/bin/helm", "bundle"])
def test_package_files_removed(ssh, path):
    assert ssh(f"test -e {path}", check=False).returncode != 0, f"{path} is still on the appliance"


def test_k3s_itself_still_healthy(kubectl, kubectl_json):
    """Uninstalling the package must not take the platform down with it."""
    kubectl("wait", "--for=condition=Ready", "node", "--all", "--timeout=60s")
    pods = kubectl_json("-n", "kube-system", "get", "pods")["items"]
    not_ok = [p["metadata"]["name"] for p in pods if p["status"]["phase"] not in ("Running", "Succeeded")]
    assert not_ok == [], f"kube-system pods not running: {not_ok}"

"""Does the installed Vault package work on the air-gapped appliance?

From "was it installed the way we intended" (no internet, every image from the bundle) to "does it do its job"
(unsealed, stores and returns secrets, enforces policy, injects secrets into application pods).
"""
import textwrap

import pytest


def test_appliance_has_no_internet(ssh):
    """The point of the whole test: if the VM could reach the internet, a missing file in the bundle would go
    unnoticed because k3s or containerd would quietly download it."""
    result = ssh("curl -sS -m 5 -o /dev/null https://registry-1.docker.io/v2/", check=False)
    assert result.returncode != 0, "the appliance can reach Docker Hub: the air gap isn't in place"


def test_vault_pods_are_running_and_ready(kubectl, kubectl_json, root_token):
    # root_token: vault-0's readiness probe only passes once Vault is unsealed
    kubectl("-n", "vault", "wait", "--for=condition=Ready", "pod", "--all", "--timeout=120s")
    pods = {p["metadata"]["name"]: p for p in kubectl_json("-n", "vault", "get", "pods")["items"]}
    assert "vault-0" in pods
    assert any(name.startswith("vault-agent-injector-") for name in pods)
    for name, pod in pods.items():
        for status in pod["status"]["containerStatuses"]:
            assert status["restartCount"] == 0, f"{name}/{status['name']} restarted {status['restartCount']} times"


def test_every_image_came_from_the_bundle(kubectl, kubectl_json, versions):
    """No image was pulled: the kubelet found each one already in containerd. With IfNotPresent and a missing image
    it would try to pull, which fails without internet, but a 'Pulling' event is the earliest, clearest sign."""
    expected = {f"hashicorp/vault:{versions['VAULT_VERSION']}", f"hashicorp/vault-k8s:{versions['VAULT_K8S_VERSION']}"}
    pods = kubectl_json("-n", "vault", "get", "pods")["items"]
    images = {c["image"].removeprefix("docker.io/") for p in pods for c in p["spec"]["containers"]}
    assert images == expected
    events = kubectl_json("-n", "vault", "get", "events")["items"]
    pulled = [e["message"] for e in events if e["reason"] in ("Pulling", "Failed", "ErrImagePull")]
    assert pulled == [], f"the kubelet tried to pull: {pulled}"


def test_vault_is_initialized_unsealed_and_the_pinned_version(vault, versions):
    health = vault.ok("GET", "sys/health")
    assert health["initialized"] is True
    assert health["sealed"] is False
    assert health["version"] == versions["VAULT_VERSION"]


def test_secret_written_can_be_read_back(vault, app_secret):
    """A functional check, not just "the pods are up": Vault stores a secret on its volume and returns it."""
    data = vault.ok("GET", app_secret["path"])["data"]["data"]
    assert data == {"password": app_secret["password"]}


def test_approle_login_gets_read_only_access(vault, app_secret):
    """AppRole is how a machine (a service, a CI job) logs in. The token it gets must allow exactly the policy."""
    vault.enable("auth", "approle", "approle")
    vault.ok("POST", "auth/approle/role/app", {"token_policies": [app_secret["policy"]], "token_ttl": "10m"})
    role_id = vault.ok("GET", "auth/approle/role/app/role-id")["data"]["role_id"]
    secret_id = vault.ok("POST", "auth/approle/role/app/secret-id")["data"]["secret_id"]

    login = vault.call("POST", "auth/approle/login", {"role_id": role_id, "secret_id": secret_id})
    assert login.status_code == 200, login.text
    token = login.json()["auth"]["client_token"]

    read = vault.call("GET", app_secret["path"], token=token)
    assert read.status_code == 200, read.text
    assert read.json()["data"]["data"]["password"] == app_secret["password"]

    write = vault.call("POST", app_secret["path"], {"data": {"password": "changed"}}, token=token)
    assert write.status_code == 403, "the read-only AppRole token could write"
    other = vault.call("GET", "sys/policies/acl", token=token)
    assert other.status_code == 403, "the read-only AppRole token could list policies"

    bad = vault.call("POST", "auth/approle/login", {"role_id": role_id, "secret_id": "not-the-secret-id"})
    assert bad.status_code in (400, 403), f"login with a wrong secret_id returned {bad.status_code}"


INJECTED_APP = textwrap.dedent("""\
    apiVersion: v1
    kind: Namespace
    metadata:
      name: demo
    ---
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: app
      namespace: demo
    ---
    apiVersion: v1
    kind: Pod
    metadata:
      name: app
      namespace: demo
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: app
        vault.hashicorp.com/agent-pre-populate-only: "true"
        vault.hashicorp.com/agent-inject-secret-config: secret/data/app/config
        vault.hashicorp.com/agent-inject-template-config: |
          {{- with secret "secret/data/app/config" -}}password={{ .Data.data.password }}{{- end -}}
    spec:
      serviceAccountName: app
      terminationGracePeriodSeconds: 5
      containers:
        - name: app
          image: hashicorp/vault:VAULT_VERSION   # already on the appliance: the test app needs no image of its own
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c", "trap 'exit 0' TERM; while true; do sleep 1; done"]
    """)


@pytest.fixture
def injected_pod(vault, app_secret, kubectl, versions):
    """Kubernetes auth in Vault, and a pod whose service account may read the app secret through it."""
    vault.enable("auth", "kubernetes", "kubernetes")
    # Vault runs in the cluster, so it uses its own service account token and CA to check pods' tokens
    vault.ok("POST", "auth/kubernetes/config", {"kubernetes_host": "https://kubernetes.default.svc"})
    vault.ok("POST", "auth/kubernetes/role/app", {
        "bound_service_account_names": ["app"], "bound_service_account_namespaces": ["demo"],
        "token_policies": [app_secret["policy"]], "token_ttl": "10m"})
    kubectl("apply", "-f", "-", stdin=INJECTED_APP.replace("VAULT_VERSION", versions["VAULT_VERSION"]))
    yield "demo", "app"
    kubectl("delete", "namespace", "demo", "--wait=false", check=False)


def test_injector_puts_the_secret_into_an_application_pod(injected_pod, kubectl, kubectl_json, app_secret):
    """The way applications get secrets on the appliance: the injector's webhook adds a Vault Agent init container,
    which logs in with the pod's service account and writes the secret to /vault/secrets/ before the app starts."""
    namespace, name = injected_pod
    wait = kubectl("-n", namespace, "wait", "--for=condition=Ready", f"pod/{name}", "--timeout=120s", check=False)
    pod = kubectl_json("-n", namespace, "get", "pod", name)
    assert pod["metadata"]["annotations"].get("vault.hashicorp.com/agent-inject-status") == "injected", \
        "the injector's webhook didn't change the pod"
    if wait.returncode != 0:
        logs = kubectl("-n", namespace, "logs", name, "-c", "vault-agent-init", check=False)
        pytest.fail(f"pod not Ready: {wait.stderr}\nvault-agent-init log:\n{logs.stdout}{logs.stderr}")
    content = kubectl("-n", namespace, "exec", name, "-c", "app", "--", "cat", "/vault/secrets/config").stdout
    assert content.strip() == f"password={app_secret['password']}"

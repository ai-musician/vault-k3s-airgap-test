#!/usr/bin/env bash
# Removes the Vault package from this machine and leaves k3s running. Runs ON the appliance, as root. Every step
# tolerates "already gone", so it also cleans up after a half-finished install. tests/uninstalled/ then checks that
# nothing is left behind.
set -euo pipefail
cd "$(dirname "$0")"
. ./versions.env
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml PATH="/usr/local/bin:$PATH"

echo "--- Helm release"
if command -v helm >/dev/null; then
  helm uninstall vault --namespace vault --ignore-not-found --wait --timeout 120s
fi

echo "--- namespaces (demo is the tests' injector app)"
kubectl delete namespace demo --ignore-not-found --wait --timeout=120s
# Helm doesn't delete a StatefulSet's PersistentVolumeClaims: Vault's data would survive an uninstall
kubectl -n vault delete pvc --all --ignore-not-found --wait --timeout=120s 2>/dev/null || true
kubectl delete namespace vault --ignore-not-found --wait --timeout=120s

echo "--- Vault's volume (local-path deletes the PV and its folder once the claim is gone)"
deadline=$((SECONDS + 120))
while kubectl get pv -o name | grep -q .; do
  [ $SECONDS -lt $deadline ] || { echo "PersistentVolumes still there:" >&2; kubectl get pv >&2; exit 1; }
  sleep 2
done

echo "--- images"
for image in "docker.io/hashicorp/vault:$VAULT_VERSION" "docker.io/hashicorp/vault-k8s:$VAULT_K8S_VERSION"; do
  k3s ctr images rm "$image" >/dev/null 2>&1 || true
done

echo "--- helm binary"
rm -f /usr/local/bin/helm
echo "--- uninstalled"

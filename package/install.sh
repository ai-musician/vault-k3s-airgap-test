#!/usr/bin/env bash
# Installs the Vault package on this machine without internet access. Runs ON the appliance, as root, from the
# unpacked bundle folder:
#   1. check every file in the bundle against SHA256SUMS
#   2. k3s from its air-gap files (binary, install script, system images)
#   3. the Vault images imported straight into k3s's containerd
#   4. Vault from the Helm chart .tgz, set never to pull an image
# Safe to run twice: each step skips what's already there.
set -euo pipefail
cd "$(dirname "$0")"
. ./versions.env
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml PATH="/usr/local/bin:$PATH"

wait_for() {  # wait_for <seconds> <description> <command...>: poll until the command succeeds, fail at the deadline
  local deadline=$((SECONDS + $1)) what=$2; shift 2
  until "$@" >/dev/null 2>&1; do
    [ $SECONDS -lt $deadline ] || { echo "timed out waiting for $what" >&2; exit 1; }
    sleep 2
  done
}

echo "--- 1. bundle checksums"
sha256sum --quiet -c SHA256SUMS
echo "all $(wc -l < SHA256SUMS) files OK"

echo "--- 2. k3s $K3S_VERSION from the air-gap bundle"
if ! command -v k3s >/dev/null; then
  # k3s imports every image tarball in this folder into containerd when it starts
  mkdir -p /var/lib/rancher/k3s/agent/images
  cp k3s-airgap-images.tar.zst /var/lib/rancher/k3s/agent/images/
  install -m 755 k3s /usr/local/bin/k3s
  # SKIP_DOWNLOAD: use the binary above instead of fetching one. traefik (ingress) isn't needed here
  INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_EXEC="--disable=traefik" sh ./k3s-install.sh
fi
# the API answers a few seconds before the node has registered itself: wait for a node, then for it to be Ready
wait_for 180 "the node to register" sh -c 'kubectl get nodes -o name | grep -q .'
kubectl wait --for=condition=Ready node --all --timeout=180s
kubectl get nodes -o wide

echo "--- 3. helm $HELM_VERSION"
if ! command -v helm >/dev/null; then
  tmp=$(mktemp -d)
  tar -xzf helm.tar.gz -C "$tmp"
  install -m 755 "$tmp"/linux-*/helm /usr/local/bin/helm
  rm -rf "$tmp"
fi
helm version --short

echo "--- 4. Vault $VAULT_VERSION and vault-k8s $VAULT_K8S_VERSION images into containerd"
k3s ctr images import vault-images.tar      # k3s ctr works in containerd's k8s.io namespace, the one the kubelet uses
k3s crictl images | grep hashicorp

echo "--- 5. Vault chart $VAULT_CHART_VERSION"
helm upgrade --install vault ./vault-chart.tgz --namespace vault --create-namespace -f vault-values.yaml \
  --set server.image.tag="$VAULT_VERSION" \
  --set injector.agentImage.tag="$VAULT_VERSION" \
  --set injector.image.tag="$VAULT_K8S_VERSION"
# no `helm --wait`: vault-0 only becomes Ready once it's initialized and unsealed, which the tests do
kubectl -n vault rollout status deployment/vault-agent-injector --timeout=180s
wait_for 60 "pod vault-0 to be created" kubectl -n vault get pod vault-0
kubectl -n vault wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 --timeout=180s
kubectl -n vault get pods,pvc,svc
echo "--- installed"

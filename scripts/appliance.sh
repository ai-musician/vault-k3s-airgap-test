#!/usr/bin/env bash
# Tests that the Vault package installs, works and uninstalls cleanly on a machine with no internet access: a
# throwaway Ubuntu VM standing in for an appliance, with k3s and Vault delivered as one offline bundle. The VM runs
# locally (Multipass, free) or on Google Cloud (Terraform in infra/gcp, about a cent a run).
#
#   scripts/appliance.sh <multipass|gcp> all        # every step below; the VM is deleted even if a step fails or
#                                                   # you press Ctrl-C, and it exits non-zero if any test failed
#   scripts/appliance.sh <multipass|gcp> bundle     # download k3s, Helm, the Vault chart and images; SHA256SUMS
#   scripts/appliance.sh <multipass|gcp> vm         # create the VM, cut off from the internet
#   scripts/appliance.sh <multipass|gcp> ship       # copy the bundle to the VM with lftp (sftp without lftp)
#   scripts/appliance.sh <multipass|gcp> install    # run the bundle's install.sh on the VM
#   scripts/appliance.sh <multipass|gcp> test       # pytest tests/installed: air gap, pods, secrets, AppRole, ...
#   scripts/appliance.sh <multipass|gcp> uninstall  # the bundle's uninstall.sh, then tests/uninstalled
#   scripts/appliance.sh <multipass|gcp> destroy    # delete the VM (and on gcp everything Terraform made)
#   scripts/appliance.sh <multipass|gcp> ssh        # a shell on the VM
#
# Needs Docker, curl, jq, python3, lftp or sftp, and: Multipass | Terraform + gcloud, logged in (gcloud auth
# application-default login). Settings, all optional:
#   ARCH        the VM's architecture, which the bundle must match: default the Mac's on multipass (arm64 on Apple
#               silicon), amd64 on gcp
#   SHIP_WITH   lftp | sftp, default lftp when installed
#   multipass:  VM_NAME (vault-appliance), VM_CPUS (2), VM_MEMORY (4G), VM_DISK (15G), UBUNTU (26.04)
#   gcp:        TF_VAR_project_id (default your gcloud project), TF_VAR_zone (us-central1-a),
#               TF_VAR_machine_type (e2-medium; for arm64 use t2a-standard-2), TF_VAR_admin_cidrs (your public IP)
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 2; }
[ $# -eq 2 ] || usage
target=$1 action=$2
case $target in multipass|gcp) ;; *) usage ;; esac
case $action in bundle|vm|ship|install|test|uninstall|destroy|ssh|all) ;; *) usage ;; esac

set -a; . ./versions.env; set +a
VM="${VM_NAME:-vault-appliance}"
if [ "$target" = gcp ]; then
  ARCH="${ARCH:-amd64}"
else
  ARCH="${ARCH:-$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')}"
fi
bundle_dir="bundle/linux-$ARCH"
state=.vm key=.vm/id_ed25519
ssh_opts=(-i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

need() { for c in "$@"; do command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }; done; }
host() { [ -f "$state/host" ] || { echo "no VM: run scripts/appliance.sh $target vm first" >&2; exit 1; }; cat "$state/host"; }
rsh()  { ssh "${ssh_opts[@]}" "$(host)" "$@"; }

# one appliance at a time: .vm/ (key, kubeconfig, Vault's unseal key) belongs to whichever target made it
if [ -f "$state/target" ] && [ "$(cat "$state/target")" != "$target" ]; then
  other=$(cat "$state/target")
  echo "a $other appliance is active: run scripts/appliance.sh $other destroy first" >&2; exit 1
fi

# --- bundle: everything the appliance needs, downloaded once on this machine and checked against upstream checksums
fetch() {  # fetch <url> <file in the bundle>; skips files already downloaded
  [ -s "$bundle_dir/$2" ] && return
  echo "  downloading $2"
  curl -fsSL --retry 3 -o "$bundle_dir/$2.part" "$1"
  mv "$bundle_dir/$2.part" "$bundle_dir/$2"
}
verify() {  # verify <file in the bundle> <expected sha256>
  local got; got=$(shasum -a 256 "$bundle_dir/$1" | cut -d' ' -f1)
  [ "$got" = "$2" ] || { echo "checksum mismatch for $bundle_dir/$1: delete it and run bundle again" >&2; exit 1; }
}
make_bundle() {
  need curl docker shasum
  echo "--- bundle for linux/$ARCH: k3s $K3S_VERSION, Helm $HELM_VERSION, Vault chart $VAULT_CHART_VERSION," \
       "Vault $VAULT_VERSION, vault-k8s $VAULT_K8S_VERSION"
  mkdir -p "$bundle_dir"
  local k3s_url="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}"
  local k3s_bin=k3s; [ "$ARCH" = amd64 ] || k3s_bin="k3s-$ARCH"
  local sums; sums=$(curl -fsSL "$k3s_url/sha256sum-$ARCH.txt")
  fetch "$k3s_url/$k3s_bin" k3s
  verify k3s "$(awk -v f="$k3s_bin" '$2 == f {print $1}' <<<"$sums")"
  fetch "$k3s_url/k3s-airgap-images-$ARCH.tar.zst" k3s-airgap-images.tar.zst
  verify k3s-airgap-images.tar.zst "$(awk -v f="k3s-airgap-images-$ARCH.tar.zst" '$2 == f {print $1}' <<<"$sums")"
  fetch "https://raw.githubusercontent.com/k3s-io/k3s/$K3S_VERSION/install.sh" k3s-install.sh

  local helm_url="https://get.helm.sh/helm-$HELM_VERSION-linux-$ARCH.tar.gz"
  fetch "$helm_url" helm.tar.gz
  verify helm.tar.gz "$(curl -fsSL "$helm_url.sha256sum" | cut -d' ' -f1)"

  fetch "https://helm.releases.hashicorp.com/vault-$VAULT_CHART_VERSION.tgz" vault-chart.tgz

  # the images the chart will run, for the VM's architecture, in one tarball for `k3s ctr images import`
  local images=("hashicorp/vault:$VAULT_VERSION" "hashicorp/vault-k8s:$VAULT_K8S_VERSION")
  if [ ! -s "$bundle_dir/vault-images.tar" ] || [ "$(cat "$bundle_dir/.images" 2>/dev/null)" != "${images[*]}" ]; then
    for image in "${images[@]}"; do docker pull --quiet --platform "linux/$ARCH" "$image"; done
    docker save --platform "linux/$ARCH" -o "$bundle_dir/vault-images.tar" "${images[@]}"
    echo "${images[*]}" > "$bundle_dir/.images"
  fi

  cp package/install.sh package/uninstall.sh package/vault-values.yaml versions.env "$bundle_dir/"
  chmod +x "$bundle_dir/install.sh" "$bundle_dir/uninstall.sh" "$bundle_dir/k3s-install.sh"
  (cd "$bundle_dir" && rm -f SHA256SUMS && shasum -a 256 -- * > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS)
  echo "--- $bundle_dir/: $(du -sh "$bundle_dir" | cut -f1)"
  cat "$bundle_dir/SHA256SUMS"
}

# --- vm: a fresh Ubuntu VM that accepts our SSH key and can't reach the internet
new_key() {
  mkdir -p "$state"
  echo "$target" > "$state/target"
  [ -f "$key" ] || ssh-keygen -q -t ed25519 -N '' -C vault-k3s-airgap-test -f "$key"
}

wait_for_ssh() {
  local deadline=$((SECONDS + $1))
  until rsh true 2>/dev/null; do
    [ $SECONDS -lt $deadline ] || { echo "can't ssh to $(host)" >&2; exit 1; }
    sleep 3
  done
}

vm_multipass() {
  need multipass jq ssh-keygen
  new_key
  if ! multipass info "$VM" >/dev/null 2>&1; then
    echo "--- creating VM $VM"
    printf '#cloud-config\nssh_authorized_keys:\n  - %s\n' "$(cat "$key.pub")" > "$state/cloud-init.yaml"
    multipass launch "${UBUNTU:-26.04}" --name "$VM" --cpus "${VM_CPUS:-2}" --memory "${VM_MEMORY:-4G}" \
      --disk "${VM_DISK:-15G}" --cloud-init "$state/cloud-init.yaml" --timeout 600
  fi
  local ip; ip=$(multipass info "$VM" --format json | jq -r --arg vm "$VM" '.info[$vm].ipv4[0]')
  echo "ubuntu@$ip" > "$state/host"
  wait_for_ssh 120
  echo "--- cutting $VM off from the internet: only private networks, loopback and replies are allowed out"
  # OUTPUT covers the host's own traffic, which is where k3s/containerd would pull images or binaries from. Pods'
  # traffic goes through FORWARD and isn't blocked: the test is whether the *installer* needs the internet.
  rsh sudo sh -s <<'EOF'
set -e
for ipt in iptables ip6tables; do
  $ipt -N AIRGAP 2>/dev/null || $ipt -F AIRGAP
  $ipt -A AIRGAP -o lo -j RETURN
  $ipt -A AIRGAP -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
done
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16; do iptables -A AIRGAP -d $net -j RETURN; done
for net in fc00::/7 fe80::/10; do ip6tables -A AIRGAP -d $net -j RETURN; done
iptables -A AIRGAP -j REJECT
ip6tables -A AIRGAP -j REJECT
for ipt in iptables ip6tables; do $ipt -C OUTPUT -j AIRGAP 2>/dev/null || $ipt -A OUTPUT -j AIRGAP; done
EOF
}

tfdir=infra/gcp
tf() { terraform -chdir="$tfdir" "$@"; }
gcp_vars() {
  need terraform gcloud curl
  export TF_IN_AUTOMATION=1 TF_VAR_name="$VM" TF_VAR_arch="$ARCH"
  TF_VAR_project_id="${TF_VAR_project_id:-$(gcloud config get-value project 2>/dev/null)}"
  [ -n "$TF_VAR_project_id" ] || { echo "set TF_VAR_project_id or: gcloud config set project <id>" >&2; exit 1; }
  export TF_VAR_project_id
  if [ -z "${TF_VAR_admin_cidrs:-}" ]; then
    local ip; ip=$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')
    TF_VAR_admin_cidrs=$(printf '["%s/32"]' "$ip")   # a Terraform list, e.g. ["203.0.113.7/32"]
    export TF_VAR_admin_cidrs
  fi
  if [ -f "$key.pub" ]; then
    TF_VAR_ssh_public_key=$(cat "$key.pub")
  else
    TF_VAR_ssh_public_key=none   # destroy needs every variable set, but not this value
  fi
  export TF_VAR_ssh_public_key
}

vm_gcp() {
  need ssh-keygen
  new_key
  gcp_vars
  echo "--- creating $VM in $TF_VAR_project_id ($ARCH, reachable from $TF_VAR_admin_cidrs only, no internet out)"
  tf init -input=false >/dev/null
  tf apply -input=false -auto-approve
  echo "ubuntu@$(tf output -raw external_ip)" > "$state/host"
  # the air gap is the VPC firewall's egress deny rule (infra/gcp/main.tf): nothing to do on the VM itself
  wait_for_ssh 240
}

make_vm() {
  "vm_$target"
  if rsh curl -sS -m 5 -o /dev/null https://github.com 2>/dev/null; then
    echo "!!! $VM can still reach the internet" >&2; exit 1
  fi
  echo "--- $VM ready at $(host), no internet"
}

# --- ship: copy the bundle like a delivery to a customer appliance, then check it arrived intact
ship_bundle() {
  [ -f "$bundle_dir/SHA256SUMS" ] || { echo "no bundle: run scripts/appliance.sh $target bundle first" >&2; exit 1; }
  local h; h=$(host)
  if [ "${SHIP_WITH:-lftp}" = lftp ] && command -v lftp >/dev/null; then
    echo "--- lftp: mirroring $bundle_dir/ to $h:bundle/"
    # mirror -R uploads only what changed; lftp retries a dropped connection
    lftp -c "set sftp:connect-program 'ssh -a -x ${ssh_opts[*]}'; set net:max-retries 3;
             open -u ${h%@*}, sftp://${h#*@}; mirror -R --delete --verbose=1 $bundle_dir bundle"
  else
    echo "--- sftp: copying $bundle_dir/ to $h:bundle/"
    sftp "${ssh_opts[@]}" -b - "$h" <<EOF
-mkdir bundle
cd bundle
lcd $bundle_dir
put *
EOF
  fi
  rsh 'cd bundle && sha256sum --quiet -c SHA256SUMS && echo "--- all $(wc -l < SHA256SUMS) files arrived intact"'
}

install_package() {
  local ip; ip=$(host); ip=${ip#*@}
  echo "--- installing on $(host)"
  # TLS_SAN: the address the tests use must be in the k3s API certificate (on gcp it's the public IP, which the VM
  # itself doesn't know about)
  rsh sudo env TLS_SAN="$ip" bundle/install.sh
  rsh sudo cat /etc/rancher/k3s/k3s.yaml | sed "s#https://127.0.0.1:6443#https://$ip:6443#" > "$state/kubeconfig"
  chmod 600 "$state/kubeconfig"
  echo "--- kubeconfig -> $state/kubeconfig   (kubectl --kubeconfig $state/kubeconfig get pods -A)"
}

venv() {
  [ -x .venv/bin/pytest ] || { python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt; }
}
run_tests() { venv; .venv/bin/pytest -v tests/installed; }

uninstall_package() {
  echo "--- uninstalling the package from $(host)"
  rsh sudo bundle/uninstall.sh
  rsh rm -rf bundle
  venv
  .venv/bin/pytest -v tests/uninstalled
}

destroy_multipass() {
  need multipass
  if multipass info "$VM" >/dev/null 2>&1; then
    echo "--- deleting VM $VM"
    multipass delete --purge "$VM"
  else
    echo "--- no VM $VM"
  fi
}

destroy_gcp() {
  if [ ! -f "$tfdir/terraform.tfstate" ]; then echo "--- nothing to destroy on gcp"; return 0; fi
  gcp_vars
  echo "--- destroying $VM in $TF_VAR_project_id"
  tf init -input=false >/dev/null
  tf destroy -input=false -auto-approve
  echo "--- destroyed; left in the state: $(tf state list | wc -l | tr -d ' ') resources"
}

destroy_vm() {
  "destroy_$target"
  rm -rf "$state"
}

case $action in
  bundle)    make_bundle ;;
  vm)        make_vm ;;
  ship)      ship_bundle ;;
  install)   install_package ;;
  test)      run_tests ;;
  uninstall) uninstall_package ;;
  destroy)   destroy_vm ;;
  ssh)       ssh "${ssh_opts[@]}" "$(host)" ;;
  all)
    # delete the VM whatever happens; keep going to uninstall even if the install tests fail, since "does it uninstall
    # cleanly" is worth knowing either way
    # shellcheck disable=SC2154  # status is assigned inside the trap
    trap 'status=$?; trap - EXIT INT TERM; destroy_vm || echo "!!! run scripts/appliance.sh $target destroy" >&2; exit $status' EXIT
    trap 'exit 130' INT TERM
    make_bundle
    make_vm
    ship_bundle
    install_package
    tests_failed=0
    run_tests || tests_failed=1
    uninstall_package
    exit $tests_failed
    ;;
esac

# vault-k3s-airgap-test

Tests that a HashiCorp Vault package **installs, works and uninstalls cleanly on a machine with no internet
access**, the way software is delivered to an appliance or an air-gapped customer site.

One command builds the package, creates a throwaway Ubuntu VM cut off from the internet, copies the package to it
over SFTP, installs k3s and Vault from it, tests Vault, uninstalls it, checks nothing was left behind, and deletes the
VM. The VM runs on your machine (Multipass, free) or on Google Cloud (about a cent a run):

```bash
scripts/appliance.sh multipass all
scripts/appliance.sh gcp all
```

## What happens

```
build machine (macOS or Linux)                       appliance VM (Ubuntu 26.04, no internet)

1. bundle   k3s binary + install script
            k3s system images (air-gap .tar.zst)
            Helm binary
            Vault Helm chart (.tgz)
            Vault + vault-k8s images (.tar)
            install.sh, uninstall.sh, values, SHA256SUMS
                                                      2. vm       multipass: Multipass VM, iptables blocks egress
                                                                  gcp: Terraform, VPC firewall denies egress
3. ship     lftp mirror (or sftp)  ───────────────►   ~/bundle/   checked against SHA256SUMS
4. install  ssh: sudo bundle/install.sh  ─────────►   k3s air-gap install
                                                      k3s ctr images import vault-images.tar
                                                      helm install vault ./vault-chart.tgz
5. test     pytest tests/installed  ──── HTTP :30820 ─► Vault API, ── kubectl :6443 ─► k3s
6. uninstall ssh: sudo bundle/uninstall.sh, then pytest tests/uninstalled
7. destroy  multipass delete --purge | terraform destroy
```

`all` deletes the VM even when a step fails or you press Ctrl-C, still runs the uninstall checks when an install test
fails, and exits non-zero if any test failed. Every step can also be run on its own (`scripts/appliance.sh` with no
arguments lists them), which is how you debug: `vm`, `ship`, `install`, then `ssh` in and look.

## What the tests check

**Installed** (`tests/installed/`)

| Test | Why it matters |
|---|---|
| The appliance can't reach the internet | Otherwise a file missing from the bundle goes unnoticed: k3s or containerd would quietly download it |
| Vault pods Running and Ready, no restarts | The install came up, and stayed up |
| Every image came from the bundle | The pinned tags, and no `Pulling` event: the kubelet found each image already in containerd |
| Vault initialized, unsealed, the pinned version | Ready to serve, and the version you meant to ship |
| A secret written can be read back | A functional check, not just "the pods are up" |
| AppRole login gets read-only access | A machine login gets exactly its policy: read works, write and admin calls are refused (403), a wrong secret ID is rejected |
| The injector puts the secret into an application pod | How apps consume secrets: the webhook adds a Vault Agent, which logs in with the pod's service account and writes `/vault/secrets/config` |

**Uninstalled** (`tests/uninstalled/`)

| Test | Why it matters |
|---|---|
| Namespaces gone | |
| No webhook, cluster role or binding left | Objects outside the namespace are what uninstalls usually miss. A leftover webhook can break the next install |
| No volume left | Helm doesn't delete a StatefulSet's volume claims, so Vault's data (secrets) would survive the uninstall |
| Images removed from containerd | |
| Helm binary and bundle removed | |
| k3s still healthy | Removing the package must not take the platform down |

**Do the uninstall checks catch anything?** Removing Vault with only `helm uninstall vault` instead of `uninstall.sh`
makes 5 of the 7 fail: the `vault` namespace, a PersistentVolume still holding Vault's data, both images, the Helm
binary and the bundle are all left behind. Helm does remove the webhook and cluster roles, so that check passes, as
it should.

## Runs

Both from a MacBook Air (Apple silicon, 16 GB) on a home connection; Ubuntu 26.04, k3s v1.37.2+k3s1, Vault 2.0.4:

| | `multipass all` | `gcp all` |
|---|---|---|
| VM | Multipass, arm64, 2 CPUs, 4 GB | e2-medium in us-central1-a, amd64 |
| Air gap | iptables on the VM | VPC firewall egress deny |
| Create the VM | under 1 minute (2 the first time, image download) | about 1.5 minutes (5 resources) |
| Ship 470-510 MB | 9 seconds | a few minutes, depends on your upload speed |
| Install, test, uninstall | about 1 minute | about 1.5 minutes |
| Delete | seconds | about 2 minutes |
| **Total, bundle already built** | **2 minutes, 14 tests passed** | **7.5 minutes, 14 tests passed** |
| Cost | free | about a cent |

After the gcp run nothing is left in the project: no instance, disk, address, network or firewall rule.

## Google Cloud

`infra/gcp/main.tf` makes one VM in its own VPC network, so its firewall rules touch nothing else in the project:

- **In:** ssh, the Kubernetes API (6443) and Vault's NodePort (30820), from your public IP only.
- **Out: nothing.** An egress deny rule for `0.0.0.0/0` is the air gap. The firewall is stateful, so replies to the
  connections above still flow, and the metadata server (DNS, the ssh key) is always reachable.
- **No service account** on the VM: it has nothing to call, so it gets no Google Cloud identity.
- A throwaway ssh key in the instance metadata, OS Login off.
- k3s gets `--tls-san <public IP>`, because the tests reach the API at an address the VM itself doesn't know.

The VM is x86 (amd64), so the bundle is built for amd64: an Apple silicon Mac building for a different
architecture, as a real release would. For an Arm VM: `ARCH=arm64 TF_VAR_machine_type=t2a-standard-2`.

Needs Terraform and gcloud with `gcloud auth application-default login`, the Compute Engine API enabled, and a
project (default: your gcloud project, or `TF_VAR_project_id`). The Terraform state stays in `infra/gcp/`
(git-ignored), so run `destroy` from the same checkout.

## Design choices

- **The air gap is real** and a test proves it. On Multipass only the host's own traffic is blocked (that's where k3s
  and containerd would download from), not pods' traffic. On Google Cloud the network blocks everything.
- **Everything is pinned and checked.** Versions are in `versions.env`. Downloads are checked against the upstream
  checksums (k3s, Helm), the bundle carries a `SHA256SUMS` for every file, and it's checked again on the appliance
  after the copy.
- **No image pulls.** Images go straight into k3s's containerd with `k3s ctr images import`. The chart uses
  `IfNotPresent` with exact tags. The injector's test app reuses the Vault image so it needs no image of its own.
- **The install and uninstall scripts are part of the package**, so the thing tested is the thing delivered. Both
  are safe to run twice.
- **Only the VM step differs between targets.** Shipping, installing and testing need nothing but ssh, so another
  cloud is one more Terraform folder and two small functions.
- **Vault is initialized with a single unseal key** stored in `.vm/` (git-ignored). Fine for a throwaway VM, wrong
  anywhere else. Real installs split the key (Shamir) or auto-unseal with a cloud KMS.

## Requirements

- macOS or Linux with Docker, curl, jq and Python 3.10+
- `lftp` (`brew install lftp`) for the copy; without it the script uses `sftp`
- multipass: [Multipass](https://multipass.run) and about 6 GB free (2 CPUs, 4 GB of memory, a 15 GB disk)
- gcp: Terraform and gcloud, as above
- Bundles are kept per architecture in `bundle/linux-<arch>/` (about 500 MB each, git-ignored)

## Not covered yet

- TLS and mTLS on Vault's listener (it's plain HTTP inside the VM)
- High availability (Raft with three replicas) and an upgrade from one package version to the next
- AWS and Azure VMs
- Running the whole flow in CI: GitHub's Linux runners could be the appliance, with no VM

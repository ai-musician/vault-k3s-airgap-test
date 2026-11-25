# vault-k3s-airgap-test

Tests that a HashiCorp Vault package **installs, works and uninstalls cleanly on a machine with no internet
access**, the way software is delivered to an appliance or an air-gapped customer site.

One command builds the package, creates a throwaway Ubuntu VM cut off from the internet, copies the package to it
over SFTP, installs k3s and Vault from it, tests Vault, uninstalls it, checks nothing was left behind, and deletes the
VM:

```bash
scripts/appliance.sh all
```

## What happens

```
build machine (macOS or Linux)                       appliance VM (Ubuntu 26.04, Multipass, no internet)

1. bundle   k3s binary + install script               
            k3s system images (air-gap .tar.zst)
            Helm binary
            Vault Helm chart (.tgz)
            Vault + vault-k8s images (.tar)
            install.sh, uninstall.sh, values, SHA256SUMS
                                                      2. vm       fresh VM, outbound internet blocked
3. ship     lftp mirror (or sftp)  ───────────────►   ~/bundle/   checked against SHA256SUMS
4. install  ssh: sudo bundle/install.sh  ─────────►   k3s air-gap install
                                                      k3s ctr images import vault-images.tar
                                                      helm install vault ./vault-chart.tgz
5. test     pytest tests/installed  ──── HTTP :30820 ─► Vault API, ── kubectl :6443 ─► k3s
6. uninstall ssh: sudo bundle/uninstall.sh, then pytest tests/uninstalled
7. destroy  multipass delete --purge
```

`all` deletes the VM even when a step fails or you press Ctrl-C, still runs the uninstall checks when an install test
fails, and exits non-zero if any test failed. Every step can also be run on its own (`scripts/appliance.sh` with no
argument lists them), which is how you debug: `vm`, `ship`, `install`, then `ssh` in and look.

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

## A run

On a MacBook Air (Apple silicon, 16 GB), Multipass 1.16, Ubuntu 26.04, k3s v1.37.2+k3s1, Vault 2.0.4:

| Step | Time |
|---|---|
| `bundle` (first time; later runs reuse it) | about 1 minute on a home connection, 473 MB |
| `vm` | under 2 minutes the first time (image download), well under 1 minute after |
| `ship` (lftp) | 9 seconds |
| `install` | 30 seconds |
| `test`, then `uninstall` | 15 seconds, 20 seconds |
| `all`, with the bundle and Ubuntu image already cached | **1 minute 54 seconds, 14 tests passed** |

## Design choices

- **The air gap is real.** Outbound traffic from the VM is blocked with iptables except to private networks, and a
  test proves it. Only the host's own traffic is blocked (that's where k3s and containerd would download from), not
  pods' traffic.
- **Everything is pinned and checked.** Versions are in `versions.env`. Downloads are checked against the upstream
  checksums (k3s, Helm), the bundle carries a `SHA256SUMS` for every file, and it's checked again on the appliance
  after the copy.
- **No image pulls.** Images go straight into k3s's containerd with `k3s ctr images import`. The chart uses
  `IfNotPresent` with exact tags. The injector's test app reuses the Vault image so it needs no image of its own.
- **The install and uninstall scripts are part of the package**, so the thing tested is the thing delivered. Both
  are safe to run twice.
- **Vault is initialized with a single unseal key** stored in `.vm/` (git-ignored). Fine for a throwaway VM, wrong
  anywhere else. Real installs split the key (Shamir) or auto-unseal with a cloud KMS.

## Requirements

- macOS or Linux with [Multipass](https://multipass.run), Docker, curl, jq and Python 3.10+
- `lftp` (`brew install lftp`) for the copy; without it the script uses `sftp`
- About 6 GB free: the VM takes 2 CPUs, 4 GB of memory and a 15 GB disk; the bundle is about 470 MB

The bundle is built for the build machine's architecture (arm64 on Apple silicon), which is what Multipass runs.
Set `ARCH=amd64` to build one for an x86 appliance.

## Not covered yet

- TLS and mTLS on Vault's listener (it's plain HTTP inside the VM)
- High availability (Raft with three replicas) and an upgrade from one package version to the next
- Running the whole flow in CI: GitHub's Linux runners could be the appliance, with no VM

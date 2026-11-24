# Manual RHEL node patching

Patch one node at a time. Complete the drain, patch, reboot, readiness checks and uncordon before moving to the next node.

## Placeholders

Replace these before running:

| Placeholder | Meaning | Example |
|---|---|---|
| `<NODE>` | Name of the node currently being patched | `worker-1` |
| `<CONTAINERD_VERSION>` | Approved containerd version | `X.Y.Z` |
| `<TARGET_KERNEL>` | Target kernel after patching | `5.14.0-xxx` |
| `<STAGING_DIR>` | Directory where the containerd tarball is staged on each node | `/opt/staging` |

The runbook assumes `kubectl` and a kubeconfig for the intended cluster are available in your Kubernetes admin session. The nodes run `containerd` from the upstream static binary tarball installed under `/usr/local/bin`.

---

## 0. Preflight

Run once from an approved admin session that can reach the Kubernetes API throughout the maintenance window.

```bash
# Confirm the context and cluster health before you start.
kubectl config current-context
kubectl get nodes -o wide
kubectl get pods -A -o wide
```

- Every node must be `Ready`.
- Check the `READY` column even for pods marked `Running`. Resolve unhealthy core services and review any known workload exceptions before moving pods.
- Confirm the containerd tarball and its `.sha256sum` are staged in `<STAGING_DIR>` on (or reachable from) each node.

If your kubeconfig requires root access, use `sudo kubectl --kubeconfig FILE` with its path for the admin commands.

---

## 1. Drain the target node

`kubectl drain` marks the node unschedulable and evicts eligible pods. Agree with the other operators who owns the cordon for this window. If the node is already cordoned, identify its owner before proceeding.

```bash
NODE='<NODE>'   # e.g. worker-1

kubectl drain "$NODE" \
  --ignore-daemonsets \
  --timeout=600s
```

- Use `--ignore-daemonsets` to leave DaemonSet pods on the node during the drain.
- Review the target pods' volume bindings and replacement capacity before draining. Add `--delete-emptydir-data` only after confirming that the contents of the affected `emptyDir` volumes can be discarded.
- If a PodDisruptionBudget blocks the drain, run `kubectl get pdb -A` and review the budget with the application owner before proceeding.

Verify the remaining pods. DaemonSets and static control-plane pods are expected where applicable.

```bash
kubectl get pods -A --field-selector "spec.nodeName=$NODE" -o wide
```

---

## 2. Patch the OS on the drained node

SSH to `<NODE>`, then:

```bash
# See what security errata are pending
sudo dnf updateinfo list security

# Apply OS security updates
sudo dnf -y update --security

# Confirm the target kernel was installed
rpm -q "kernel-core-<TARGET_KERNEL>"
sudo grubby --default-kernel
```

- If `dnf updateinfo list security` omits an expected advisory, check the installed package against the advisory's fixed version and confirm the enabled repositories carry it. If you use Satellite, check that the host's content view was published and promoted.

---

## 3. Upgrade containerd (binary swap)

Use the upstream binary tarball for the approved containerd version, `<CONTAINERD_VERSION>`.

Still on the drained node:

```bash
cd -- '<STAGING_DIR>' || exit 1
archive='containerd-<CONTAINERD_VERSION>-linux-amd64.tar.gz'

# 3a. Verify download integrity FIRST
sha256sum -c "$archive.sha256sum" || exit 1
# must print:  containerd-<CONTAINERD_VERSION>-linux-amd64.tar.gz: OK

# 3b. Record current version (for rollback reference)
containerd --version

# 3c. Stop kubelet + containerd
sudo systemctl stop kubelet
sudo systemctl stop containerd

# 3d. Extract OVER the existing binaries
sudo tar -C /usr/local -xzvf "$archive"

# 3e. Reload systemd and bring services back up
sudo systemctl daemon-reload
sudo systemctl start containerd
sudo systemctl start kubelet
```

> **Path note:** the release tarball's internal layout is `bin/containerd`, `bin/ctr`, etc., so `-C /usr/local` places them at `/usr/local/bin/...`. Confirm with `which containerd` before extracting. If yours lives in `/usr/bin`, extract to a temp dir and copy the binaries over the existing ones instead.

Verify the swap:

```bash
containerd --version
sudo systemctl status containerd --no-pager
sudo systemctl status kubelet --no-pager
```

---

## 4. Reboot for the new kernel

```bash
sudo reboot
```

Wait for the node to return, SSH back in, and confirm:

```bash
uname -r                                        # should show <TARGET_KERNEL>
containerd --version                            # should show <CONTAINERD_VERSION>
sudo systemctl is-active containerd             # should show active
sudo systemctl is-active kubelet                # should show active
```

---

## 5. Verify and uncordon

From the Kubernetes admin session, confirm the node is `Ready` and reports the expected runtime version.

```bash
# Node should return to Ready on its own as kubelet rejoins
kubectl get nodes -o wide

# Confirm the node reports the new containerd runtime
kubectl get node "$NODE" -o wide
# CONTAINER-RUNTIME column should read containerd://<CONTAINERD_VERSION>
```

Only the operator responsible for the manual cordon should release it, after confirming that all work requiring it has finished. For a `k8s-maintenance` run, follow the guide for [return](maintenance.md#apply-and-return) or [manual recovery](maintenance.md#manual-recovery).

```bash
kubectl uncordon "$NODE"

# Confirm pods are rescheduling and nothing cluster-wide is broken
kubectl get pods -A -o wide
```

**Do not move to the next node until `$NODE` is `Ready`, the runtime shows `containerd://<CONTAINERD_VERSION>`, and there are no new broken pods.**

Repeat **Steps 1–5** for the next node.

---

## 6. Order of nodes

1. All **workers**, one at a time.
2. All **control-plane nodes**, one at a time. If you run the admin session on one of those nodes, patch it last and move the session to another approved host before draining it.

For control-plane nodes, verify quorum and leader placement, confirm a recoverable etcd snapshot, and check the direct API and any load-balanced endpoint. Where applicable, take only the target API backend out of rotation on each load-balancer peer. After reboot, verify etcd and the direct API before restoring the backend and scheduling.

---

## Rollback if a node won't come back `Ready`

- **containerd:** re-extract the previous tarball version over `/usr/local`, `daemon-reload`, restart `containerd` + `kubelet`.
- **Kernel rollback.** Run `grubby --info=ALL` to list installed kernel entries. Reboot and select the previous kernel in GRUB.
- If the node still won't rejoin, keep it cordoned and escalate. Confirm workload availability and capacity before touching another node.

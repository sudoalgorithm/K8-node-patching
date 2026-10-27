# Kubernetes Node Patching Runbook

A step-by-step runbook for patching Kubernetes nodes on RHEL-family hosts: applying OS security errata **and** upgrading the `containerd` runtime binary, one node at a time, with zero cluster downtime.

> **Golden rule:** patch **one node at a time** — fully drain → patch → reboot → verify `Ready` → uncordon — before touching the next. Never patch two nodes in parallel.

---

## Placeholders

Replace these before running:

| Placeholder | Meaning | Example |
|---|---|---|
| `<KUBECONFIG_MASTER_IP>` | IP of the control-plane node that holds the kubeconfig | `10.0.0.11` |
| `<NODE>` | Name of the node currently being patched | `worker-1` |
| `<CONTAINERD_VERSION>` | Target containerd version | `2.0.12` |
| `<TARGET_KERNEL>` | Target kernel after patching | `5.14.0-xxx` |
| `<STAGING_DIR>` | Directory where the containerd tarball is staged on each node | `/opt/staging` |

This runbook assumes:
- `kubectl` is on your `PATH`.
- The kubeconfig lives at `/etc/kubernetes/admin.conf` (adjust if yours differs).
- `containerd` is installed as the upstream static binary tarball under `/usr/local/bin` (not an RPM).

---

## 0. Pre-flight

Run once, from the control-plane node that holds the kubeconfig (`<KUBECONFIG_MASTER_IP>`).

```bash
# Set the kubeconfig once for this session so you don't repeat the flag
export KUBECONFIG=/etc/kubernetes/admin.conf

# Confirm the cluster is healthy BEFORE you start
kubectl get nodes -o wide
kubectl get pods -A | grep -vE 'Running|Completed'
```

- Every node must be `Ready`.
- No un-`Ready` / crash-looping pods before you begin. If something is already broken, fix it first — don't patch on top of a sick cluster.
- Confirm the containerd tarball and its `.sha256sum` are staged in `<STAGING_DIR>` on (or reachable from) each node.

> **`sudo` + `export` caveat:** if your kubeconfig is only root-readable, note that `sudo` starts a fresh environment, so a plain `export KUBECONFIG=...` won't carry into `sudo kubectl`. Either use `sudo -E kubectl ...` (preserves your env) or run inside a root shell (`sudo -i`) that sets `KUBECONFIG` itself. If you run as a user that owns a readable kubeconfig (e.g. `~/.kube/config`), drop `sudo` entirely.

**Patch order:** workers first, then control-plane nodes one at a time. Patch the **non-kubeconfig control-plane nodes first** and the kubeconfig holder **last**, so you always keep a working seat to run `kubectl` from.

---

## 1. Drain the target node

`kubectl drain` **cordons the node (marks it unschedulable) and evicts its pods in a single command** — no separate `cordon` step is needed.

```bash
NODE=<NODE>   # e.g. worker-1

kubectl drain $NODE \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --timeout=600s
```

- `--ignore-daemonsets` is required — DaemonSet pods can't be evicted, and that's expected.
- `--delete-emptydir-data` handles pods using `emptyDir` volumes.
- If drain stalls on a PodDisruptionBudget, inspect what's blocking (`kubectl get pdb -A`) — don't force past a PDB blindly; confirm with the app owner.

Verify (only DaemonSet pods should remain on the node):

```bash
kubectl get pods -A -o wide | grep $NODE
```

---

## 2. Patch the OS (on the drained node)

SSH to `<NODE>`, then:

```bash
# See what security errata are pending
sudo dnf updateinfo list security

# Apply OS security updates
sudo dnf -y update --security

# Confirm the target kernel was installed
rpm -q kernel | tail -1
```

- If `dnf updateinfo list security` is **empty** but your scanner says the host is behind, your patch source (e.g. a Satellite/managed content view) likely wasn't published/promoted. Syncing errata alone isn't enough — the content view must be re-published so hosts see it via `dnf`.

---

## 3. Upgrade containerd (binary swap)

`containerd` here is the **upstream static binary tarball**, not an RPM — so it's a manual swap, not a `dnf` update. Target: **containerd `<CONTAINERD_VERSION>`**.

Still on the drained node:

```bash
cd <STAGING_DIR>

# 3a. Verify download integrity FIRST
sha256sum -c containerd-<CONTAINERD_VERSION>-linux-amd64.tar.gz.sha256sum
# must print:  containerd-<CONTAINERD_VERSION>-linux-amd64.tar.gz: OK

# 3b. Record current version (for rollback reference)
containerd --version

# 3c. Stop kubelet + containerd
sudo systemctl stop kubelet
sudo systemctl stop containerd

# 3d. Extract OVER the existing binaries
sudo tar -C /usr/local -xzvf containerd-<CONTAINERD_VERSION>-linux-amd64.tar.gz

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

## 4. Reboot (for the new kernel)

```bash
sudo reboot
```

Wait for the node to return, SSH back in, and confirm:

```bash
uname -r                                        # should show <TARGET_KERNEL>
containerd --version                            # should show <CONTAINERD_VERSION>
sudo systemctl is-active containerd kubelet     # both: active
```

---

## 5. Verify & uncordon

`drain` cordoned the node on the way in; **nothing un-cordons automatically**, so you must `uncordon` it yourself once it's back `Ready`.

Back on the kubeconfig node:

```bash
# Node should return to Ready on its own as kubelet rejoins
kubectl get nodes -o wide

# Confirm the node reports the new containerd runtime
kubectl get node $NODE -o wide
# CONTAINER-RUNTIME column should read containerd://<CONTAINERD_VERSION>

# Once it is Ready, allow scheduling again
kubectl uncordon $NODE

# Confirm pods are rescheduling and nothing cluster-wide is broken
kubectl get pods -A | grep -vE 'Running|Completed'
```

**Do not move to the next node until `$NODE` is `Ready`, the runtime shows `containerd://<CONTAINERD_VERSION>`, and there are no new broken pods.**

Repeat **Steps 1–5** for the next node.

---

## 6. Order of nodes

1. All **workers**, one at a time.
2. **Control-plane nodes** — the non-kubeconfig ones first.
3. **Kubeconfig holder last.** When draining the last control-plane node, point `KUBECONFIG` at an already-patched node's kubeconfig (or copy it to your workstation first) so you don't lose your control-plane seat.

---

## Rollback (if a node won't come back `Ready`)

- **containerd:** re-extract the previous tarball version over `/usr/local`, `daemon-reload`, restart `containerd` + `kubelet`.
- **kernel:** reboot and select the prior kernel entry in GRUB (`grubby --info=ALL` lists them; the old kernel stays installed).
- If the node still won't rejoin, keep it cordoned, leave it out of the cluster, and escalate. The rest of the cluster is unaffected because you only ever touched one node.

---

## License

MIT — see `LICENSE`.

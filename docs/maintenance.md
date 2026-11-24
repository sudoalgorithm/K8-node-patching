# Kubernetes worker maintenance

`bin/k8s-maintenance` runs a Bash action on one worker between a verified drain and a verified return to service. Run the CLI as your login user in the worker and Kubernetes admin sessions. Reuse the same account for every phase that uses a given run directory. Copy `bin/k8s-maintenance` and `hack/utils.bash` to each host, keeping their relative paths.

Both sessions need Bash and standard shell utilities. The worker needs Linux, `ip` and `sha256sum`. The admin session needs `kubectl`, API access and permission to inspect cluster health, read node leases in `kube-node-lease`, patch node taints, read pod controllers, create pod evictions, and manage the `k8s-maintenance-lock` ConfigMap in `kube-system`. Target a worker node and keep the same CLI version through the run.

Replace `worker-1.example.net` and `192.0.2.21` with the worker's Kubernetes node name and IPv4 InternalIP. Replace `example-admin` with the kubeconfig context for your cluster.

## Prepare the action on the worker

Put the maintenance commands in a Bash file. To restart a systemd-managed agent and check it afterward, use the following two files with your service name.

`restart-agent.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
sudo systemctl restart example-agent.service
```

`check-agent.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
systemctl is-active --quiet example-agent.service
```

```bash
bin/k8s-maintenance prepare --run "$HOME/worker-1-maintenance" \
  --node worker-1.example.net --ip 192.0.2.21 \
  --action "$HOME/restart-agent.sh" --check "$HOME/check-agent.sh"
```

`prepare` copies and checks the Bash files. They run as your worker login user, with `MAINTENANCE_NODE` and `MAINTENANCE_IP` set. Include any approved `sudo` commands in the action or check that needs them. An action or check exits nonzero to stop the workflow. Use absolute paths for files the scripts need, and keep credentials out of their output.

Add `--reboot` when the worker needs to reboot after the action. Keep the CLI, its helper and the worker run directory on storage that survives the reboot, such as a persistent home directory. The worker rejects run directories under `/tmp` or `/run` and on `tmpfs` or `ramfs` for reboot runs. This option requests `systemctl reboot`, using `sudo` for a non-root login. For a reboot-only run, supply `--reboot` on its own. Supply `--check` to confirm the specific change on the worker.

## Inspect and drain from the admin session

Transfer `worker-1-maintenance/evidence/prepared.ticket` to the admin session.

```bash
bin/k8s-maintenance inspect --run "$HOME/worker-1-cluster" \
  --context example-admin --ticket "$HOME/prepared.ticket"

# Review before-target-pods.txt, before-pdb.txt, before-pv.txt and before-issues.txt.
bin/k8s-maintenance drain --run "$HOME/worker-1-cluster"
```

Use `--kubeconfig FILE --sudo-kubectl` on `inspect` if the admin kubeconfig needs sudo. The CLI remembers this setting for the remaining cluster phases. Before eviction, `drain` waits for a fresh node heartbeat, checks cluster health and takes the cluster-wide reservation. An unhealthy node or another cordoned node blocks the health check. Coordinate that work before starting this one. Drain adds a `k8s-maintenance/hold=<reservation UID>:NoSchedule` taint. `kubectl get nodes` can still show the worker as schedulable. Inspect `spec.taints` to see the hold. Manual cordons and other taints remain under their owners' control.

The CLI sends `policy/v1` eviction requests for reviewed pods managed by a ReplicaSet, StatefulSet, Job or ReplicationController. It checks the controller UID before eviction. Other workload controllers require manual handling. PodDisruptionBudgets and graceful termination apply. If a new workload appears on the target after inspection, review it in a fresh inspect run. Cancel the incomplete run first if it holds a reservation. Review replacement capacity and volume placement before draining. Use `--allow-emptydir` only for reviewed pods whose scratch data may be lost. Pass approved baseline issues as exact rows from `before-issues.txt` with `--allow-existing FILE`.

Reserve the maintenance taint key for this CLI. Kubernetes allows direct pod binding and scheduling with a matching toleration. The CLI stops on target workloads that tolerate its hold and checks for remaining workloads before issuing a drain ticket. Coordinate new direct bindings and workloads that can bypass the hold throughout maintenance. [Kubernetes taints and tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)

For each DaemonSet on the worker, drain checks the controller's current pod template before reserving the worker and again before issuing a ticket. A replacement pod must be able to run while the hold is active. If drain names an incompatible DaemonSet, review its template with its owner. A toleration scoped to `key: k8s-maintenance/hold`, `operator: Exists`, `effect: NoSchedule` covers the CLI's per-run taint value. Drain also checks that each DaemonSet recorded at inspection has a Ready pod on this worker. Coordinate DaemonSet changes until return completes. [Kubernetes DaemonSet tolerations](https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/#taints-and-tolerations)

## Apply and return

Transfer `worker-1-cluster/evidence/drained.ticket` to the worker.

```bash
bin/k8s-maintenance apply --run "$HOME/worker-1-maintenance" --ticket "$HOME/drained.ticket"
```

`apply` verifies the staged scripts, runs the action, and saves its output. With `--reboot`, it requests the reboot after the action passes. Reconnect and run `bin/k8s-maintenance verify --run "$HOME/worker-1-maintenance"` after boot. For an action without a reboot, `apply` runs the verification in the same invocation.

Transfer `worker-1-maintenance/evidence/verified.ticket` back to the admin session after the final worker check. If you rerun verification, discard any copy already transferred. The admin session cannot see a later check failure on the worker. Wait for the new verification to pass and transfer its ticket before running `return`.

```bash
bin/k8s-maintenance return --run "$HOME/worker-1-cluster" --ticket "$HOME/verified.ticket"
```

`return` waits for a fresh kubelet heartbeat and verifies node, workload, DaemonSet and CSI health before removing this run's taint. A worker cordoned by another operator stays cordoned. Archive the evidence from each run directory with `bin/k8s-maintenance archive --run DIR`, which uses `tar` and `sha256sum`. Each invocation prints the archive and checksum paths in a new private directory under the run directory. [Kubernetes node heartbeats](https://kubernetes.io/docs/reference/node/node-status/#heartbeats)

## Resume after a failure

- If drain is blocked, resolve the blocker and retry. If the run holds the reservation and has yet to issue a drain ticket, `cancel --run DIR` waits for a fresh kubelet heartbeat before removing its own taint. It releases the reservation after cluster health recovers.
- If an action fails, the maintenance hold stays in place. Review `evidence/maintenance-action.txt` and the changes the action made. Use `apply --retry-action` with the original ticket once it is safe to rerun the script.
- After a successful action, retry a failed reboot request with `reboot --run DIR` or a failed host check with `verify --run DIR`. Once the action is recorded as complete, retries skip it. A new verification attempt clears any previous worker verification ticket.
- If cluster recovery blocks the return, resolve the issue and rerun `return` with the same verification ticket. Keep any manual pod placement or scheduling changes coordinated with the operator holding the ticket.
- After a lost API response, retry from the original admin run directory. The CLI checks the reservation's admin identity, worker run and node before resuming. A changed node version or foreign hold stops the write. Review the live node and reservation before retrying.
- For a run started with the older cordon-based CLI, review its live cordon and reservation with the original operator. The new CLI refuses those admin runs and old drain tickets. Start a fresh run after the earlier maintenance is closed.
- A hard kill or reboot can leave a `.busy` directory in the run directory. Remove it with `rmdir` only after confirming that the previous invocation and its maintenance commands have ended.

## Manual recovery

Use this procedure if the worker boot or kernel changed unexpectedly and the original run can no longer complete. If only a DaemonSet template changed, have its owner restore the matching toleration, wait for a Ready pod on the worker and retry the original phase.

1. Stop the run in both sessions. Account for any transferred tickets and confirm with the worker operator that maintenance and reboot commands have ended. Check the host's current boot ID, kernel and maintenance result. Inspect the live node, its renewing kubelet lease, workloads, DaemonSets and CSI registrations. Agree with the scheduling owner when ordinary pods may return. If the hold itself prevents recovery, have that owner keep a manual cordon in place during the repair.
2. From the original admin session, compare the live cluster, node and reservation with the run evidence. The `kube-system` namespace UID must match `evidence/cluster-uid.txt`. The reservation UID, admin ID, run ID and node name must match `evidence/reservation-uid.txt`, `admin-id` and `evidence/prepared.ticket`. If the directory was lost, restore it from backup or establish these identities from independent maintenance records with the original operator. Leave resources in place if ownership is uncertain.

   With verified external records, set `k` to the original kubectl command and populate `cluster_uid`, `node_uid`, `lock_uid`, `admin_id`, `run_id` and `node` from those records. Continue at `reservation_version`.

```bash
run="$HOME/worker-1-cluster"
k=(kubectl --context="$(<"$run/context")")
config=$(<"$run/kubeconfig")
if [[ $config ]]; then
  k+=(--kubeconfig="$config")
fi
if [[ $(<"$run/sudo-kubectl") == 1 ]]; then
  k=(sudo "${k[@]}")
fi
IFS='|' read -r _ run_id node _ < "$run/evidence/prepared.ticket"
cluster_uid=$(<"$run/evidence/cluster-uid.txt")
node_uid=$(<"$run/evidence/node-uid.txt")
lock_uid=$(<"$run/evidence/reservation-uid.txt")
admin_id=$(<"$run/admin-id")
reservation_version() (
  set -eu
  [[ $("${k[@]}" get namespace kube-system -o jsonpath='{.metadata.uid}') == "$cluster_uid" ]] || exit 1
  lock=$("${k[@]}" -n kube-system get configmap k8s-maintenance-lock -o go-template='{{.metadata.uid}}|{{index .data "admin"}}|{{index .data "run"}}|{{index .data "node"}}|{{.metadata.resourceVersion}}')
  [[ ${lock%|*} == "$lock_uid|$admin_id|$run_id|$node" ]] || exit 1
  printf '%s\n' "${lock##*|}"
)
"${k[@]}" -n kube-system get configmap k8s-maintenance-lock -o yaml
"${k[@]}" get node "$node" -o go-template='{{.metadata.uid}} {{.metadata.resourceVersion}}{{"\n"}}{{range $i,$t := .spec.taints}}{{$i}} {{$t.key}} {{or $t.value ""}} {{$t.effect}}{{"\n"}}{{end}}'
```

3. Locate the one taint whose key, value and effect match this run. If it is already absent, proceed to the health checks. If its value names a different reservation, stop. Enter the node resource version and zero-based taint index from the reviewed output. The API tests the original node UID, version and complete taint before removing that one entry. If any test fails, reread the live objects and reconcile the change.

```bash
read -r -p 'Reviewed node resource version: ' node_rv
read -r -p 'Reviewed maintenance taint index: ' index
path="/spec/taints/$index"
patch=$(printf '[{"op":"test","path":"/metadata/uid","value":"%s"},{"op":"test","path":"/metadata/resourceVersion","value":"%s"},{"op":"test","path":"%s","value":{"key":"k8s-maintenance/hold","value":"%s","effect":"NoSchedule"}},{"op":"remove","path":"%s"}]' "$node_uid" "$node_rv" "$path" "$lock_uid" "$path")
[[ $index =~ ^[0-9]+$ && $node_rv =~ ^[a-zA-Z0-9._:-]+$ ]] && reservation_version >/dev/null &&
  "${k[@]}" patch node "$node" --type=json -p "$patch"
```

4. Verify the worker is Ready, its lease advances, and the expected workloads, DaemonSets and CSI registrations have recovered. Confirm the run's taint is gone. Release the cluster reservation last. The following command compares the live ownership fields with the original evidence and submits a delete conditional on that exact object version. Coordinate any manual cordon separately with its owner. Archive the interrupted run and use fresh tickets for future work.

```bash
(
  set -eu -o pipefail
  lock_rv=$(reservation_version)
  printf '{"apiVersion":"v1","kind":"DeleteOptions","preconditions":{"uid":"%s","resourceVersion":"%s"}}\n' "$lock_uid" "$lock_rv" |
    "${k[@]}" delete --raw /api/v1/namespaces/kube-system/configmaps/k8s-maintenance-lock -f -
)
```

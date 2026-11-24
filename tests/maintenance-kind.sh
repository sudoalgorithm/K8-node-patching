#!/usr/bin/env bash
set -e -u -o pipefail

root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d)
cluster="maintenance-test-$$"
worker="$cluster-worker"
cli="$root/bin/k8s-maintenance"
host_dir=/opt/maintenance-test
admin_run="$work/admin"
export KUBECONFIG="$work/kubeconfig"

fail() {
	printf 'FAIL %s\n' "$*" >&2
	exit 1
}

expect_failure() {
	local reason=$1
	shift
	if "$@" >"$work/failure.log" 2>&1 || ! grep -Fq -- "$reason" "$work/failure.log"; then
		cat "$work/failure.log" >&2
		fail "Expected failure containing '$reason'"
	fi
}

scheduling() {
	kubectl get node "$worker" -o go-template='{{if .spec.unschedulable}}cordoned{{else}}schedulable{{end}}'
}

hold() {
	kubectl get node "$worker" -o go-template='{{range .spec.taints}}{{if and (eq .key "k8s-maintenance/hold") (eq .effect "NoSchedule")}}{{.value}}{{end}}{{end}}'
}

reservation() {
	kubectl -n kube-system get configmap k8s-maintenance-lock --ignore-not-found -o jsonpath='{.metadata.uid}'
}

host() {
	docker exec "$worker" "$host_dir/bin/k8s-maintenance" "$@" --run "$host_dir/run"
}

cleanup() {
	kind delete cluster --name "$cluster"
	rm -rf -- "$work"
}

if kind get clusters | grep -Fxq "$cluster"; then
	fail "Cluster $cluster already exists"
fi
trap cleanup EXIT
expect_failure 'Unknown option' "$cli" drain --help:typo
expect_failure 'Unknown option' "$cli" archive --run:typo "$work"
cat >"$work/kind.yaml" <<'YAML'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
YAML
kind create cluster --name "$cluster" --config "$work/kind.yaml" --image "${KIND_NODE_IMAGE:-kindest/node:v1.32.8}" --wait 120s
kubectl wait --for=condition=Ready nodes --all --timeout=90s
kubectl wait --for=condition=Ready pods -A --all --timeout=90s
pause_image=$(docker exec "$worker" crictl images | awk '$1 == "registry.k8s.io/pause" && !found {print $1 ":" $2; found=1}')
[[ -n $pause_image ]] || fail 'No pause image in the kind node'

mkdir "$work/bin"
export REAL_KUBECTL
REAL_KUBECTL=$(command -v kubectl)
export TEST_WORKER="$worker" TEST_DIR="$work"
cat >"$work/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
set -eu
case "${FAULT:-}: $* " in
before-hold:*' patch node '*)
	echo 'Interrupted before placing the hold' >&2
	exit 1
	;;
ambiguous-hold:*' get node '*)
	"$REAL_KUBECTL" "$@" | awk 'NR == 1 {sub(/\|[0-9]+=/, "|0=foreign,1=")} {print}'
	exit
	;;
daemonset-drift:*' patch node '*)
	"$REAL_KUBECTL" "$@"
	"$REAL_KUBECTL" patch daemonset maintenance-agent --type=merge -p '{"spec":{"template":{"spec":{"tolerations":[]}}}}' >&2
	exit
	;;
replace-pod:*'/pods/stable-0/eviction '*)
	old=$("$REAL_KUBECTL" get pod stable-0 -o jsonpath='{.metadata.uid}')
	"$REAL_KUBECTL" delete pod stable-0 --wait=true >&2
	for ((i = 0; i < 30; i++)); do
		new=$("$REAL_KUBECTL" get pod stable-0 --ignore-not-found -o jsonpath='{.metadata.uid}')
		if [[ $new && $new != "$old" ]]; then
			printf '%s\n' "$new" >"$TEST_DIR/replacement-uid"
			break
		fi
		sleep 1
	done
	;;
late-cordon:*' create configmap k8s-maintenance-lock '*)
	"$REAL_KUBECTL" cordon "$TEST_WORKER" >&2
	;;
patch-conflict:*' patch node '*)
	"$REAL_KUBECTL" cordon "$TEST_WORKER" >&2
	"$REAL_KUBECTL" taint node "$TEST_WORKER" audit=keep:PreferNoSchedule --overwrite >&2
	;;
lock-conflict:*' delete --raw /api/v1/namespaces/kube-system/configmaps/k8s-maintenance-lock '*)
	"$REAL_KUBECTL" -n kube-system patch configmap k8s-maintenance-lock --type=merge -p '{"data":{"admin":"another-operator"}}' >&2
	;;
lost-create:*' create configmap k8s-maintenance-lock '*)
	"$REAL_KUBECTL" "$@" >/dev/null
	touch "$TEST_DIR/created"
	exit 1
	;;
lost-create:*' get configmap k8s-maintenance-lock '*)
	[[ ! -e $TEST_DIR/created ]] || exit 1
	;;
cordon:*' get lease '*)
	if mkdir "$TEST_DIR/cordon-fired" 2>/dev/null; then
		"$REAL_KUBECTL" cordon "$TEST_WORKER" >&2
	fi
	;;
pending:*' get lease '*)
	if mkdir "$TEST_DIR/pending-fired" 2>/dev/null; then
		"$REAL_KUBECTL" run unplaceable --image=registry.k8s.io/pause:3.10 --restart=Never \
			--overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"absent-node"}}}' >&2
	fi
	;;
esac
exec "$REAL_KUBECTL" "$@"
SHIM
chmod +x "$work/bin/kubectl"
export PATH="$work/bin:$PATH"

docker exec "$worker" mkdir "$host_dir"
docker cp "$root/bin" "$worker:$host_dir/bin"
docker cp "$root/hack" "$worker:$host_dir/hack"
printf 'echo ran >> %s/attempts\n' "$host_dir" >"$work/action.sh"
docker cp "$work/action.sh" "$worker:$host_dir/action.sh"
ip=$(kubectl get node "$worker" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
host prepare --node "$worker" --ip "$ip" --action "$host_dir/action.sh"
docker cp "$worker:$host_dir/run/evidence/prepared.ticket" "$work/prepared"
"$cli" inspect --run "$admin_run" --ticket "$work/prepared" --context "kind-$cluster"

FAULT=cordon expect_failure 'Another operator cordoned' "$cli" drain --run "$admin_run"
[[ $(scheduling) == cordoned && -z $(reservation) ]] || fail 'Drain adopted an external cordon'
kubectl uncordon "$worker"

FAULT=pending expect_failure 'Cluster pre-drain checks failed' "$cli" drain --run "$admin_run"
[[ $(scheduling) == schedulable && -z $(reservation) ]] || fail 'Unhealthy drain changed scheduling'
kubectl delete pod unplaceable --wait=true
rmdir "$work/pending-fired"

FAULT=late-cordon expect_failure 'scheduling changed' "$cli" drain --run "$admin_run"
[[ $(scheduling) == cordoned && -z $(hold) && -n $(reservation) ]] || fail 'Late cordon was adopted'
"$cli" cancel --run "$admin_run" --wait 40
[[ $(scheduling) == cordoned && -z $(hold) && -z $(reservation) ]] || fail 'Cancel cleared an external cordon'
kubectl uncordon "$worker"

admin_run="$work/interrupted"
"$cli" inspect --run "$admin_run" --ticket "$work/prepared" --context "kind-$cluster"
"$cli" inspect --run "$work/other-admin" --ticket "$work/prepared" --context "kind-$cluster"
FAULT=lost-create expect_failure 'Could not read' "$cli" drain --run "$admin_run"
uid=$(reservation)
[[ -n $uid && ! -e $admin_run/evidence/reservation-uid.txt ]] || fail 'Expected a lost reservation response'
expect_failure 'no matching worker' "$cli" cancel --run "$work/other-admin"
[[ $(reservation) == "$uid" && -z $(hold) ]] || fail 'Another admin run took over the reservation'
"$cli" cancel --run "$admin_run" --wait 40
[[ -z $(reservation) && $(scheduling) == schedulable ]] || fail 'The creating run could not recover its reservation'

owner_uid=$(kubectl create configmap passive-owner -o jsonpath='{.metadata.uid}')
kubectl run manual-workload --image="$pause_image" --restart=Never \
	--overrides="{\"metadata\":{\"ownerReferences\":[{\"apiVersion\":\"v1\",\"kind\":\"ConfigMap\",\"name\":\"passive-owner\",\"uid\":\"$owner_uid\",\"controller\":true}]},\"spec\":{\"nodeName\":\"$worker\"}}"
kubectl wait --for=condition=Ready pod/manual-workload --timeout=60s
pod_uid=$(kubectl get pod manual-workload -o jsonpath='{.metadata.uid}')
"$cli" inspect --run "$work/passive" --ticket "$work/prepared" --context "kind-$cluster"
expect_failure 'unsupported controller' "$cli" drain --run "$work/passive"
[[ $(kubectl get pod manual-workload -o jsonpath='{.metadata.uid}{.metadata.deletionTimestamp}') == "$pod_uid" && -z $(reservation) && -z $(hold) ]] || fail 'Drain disrupted a pod with a passive owner'
kubectl delete pod manual-workload --wait=true
kubectl delete configmap passive-owner

# Keep the PDB-protected pod on the target worker.
kubectl create deployment protected --image="$pause_image" --dry-run=client -o yaml >"$work/deployment.yaml"
kubectl patch --local -f "$work/deployment.yaml" --type=merge \
	-p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"$worker\"}}}}}" -o yaml | kubectl create -f -
kubectl rollout status deployment/protected --timeout=60s
protected=$(kubectl get pods -l app=protected -o jsonpath='{.items[0].metadata.name}')
protected_uid=$(kubectl get pod "$protected" -o jsonpath='{.metadata.uid}')
expect_failure 'inventory changed since inspect' "$cli" drain --run "$work/other-admin"
[[ -z $(reservation) && -z $(hold) ]] || fail 'Drain adopted a workload that arrived after inspect'
kubectl create pdb protected --selector=app=protected --min-available=1
kubectl wait --for=jsonpath='{.status.disruptionsAllowed}'=0 pdb/protected --timeout=40s
admin_run="$work/protected-admin"
"$cli" inspect --run "$admin_run" --ticket "$work/prepared" --context "kind-$cluster"
expect_failure 'disruption budget' "$cli" drain --run "$admin_run" --drain-timeout 5
[[ $(kubectl get pod "$protected" -o jsonpath='{.metadata.uid}{.metadata.deletionTimestamp}') == "$protected_uid" ]] || fail 'PDB refusal disrupted the protected pod'
uid=$(reservation)
[[ -n $uid && $(hold) == "$uid" && $(scheduling) == schedulable && ! -e $admin_run/evidence/drained.ticket ]] || fail 'Expected a held worker after PDB refusal'
docker exec "$worker" systemctl stop kubelet
expect_failure 'did not renew its Kubernetes heartbeat' "$cli" cancel --run "$admin_run" --wait 3
[[ $(hold) == "$uid" && $(reservation) == "$uid" ]] || fail 'Cancel released a worker with a stale lease'
docker exec "$worker" systemctl start kubelet
kubectl cordon "$worker"
"$cli" cancel --run "$admin_run" --wait 40
[[ $(scheduling) == cordoned && -z $(hold) && -z $(reservation) ]] || fail 'Cancel removed a concurrent manual cordon'
kubectl uncordon "$worker"

kubectl delete pdb protected
kubectl delete deployment protected --cascade=foreground --wait=true
# A directly bound StatefulSet can recreate a pod on a held node with the same name.
kubectl create -f - <<YAML
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: stable}
spec:
  serviceName: stable
  replicas: 1
  selector: {matchLabels: {app: stable}}
  template:
    metadata: {labels: {app: stable}}
    spec:
      nodeName: $worker
      terminationGracePeriodSeconds: 1
      containers:
        - {name: app, image: "$pause_image", imagePullPolicy: IfNotPresent}
YAML
kubectl rollout status statefulset/stable --timeout=90s
admin_run="$work/replacement"
"$cli" inspect --run "$admin_run" --ticket "$work/prepared" --context "kind-$cluster"
FAULT=replace-pod expect_failure 'Drain did not complete' "$cli" drain --run "$admin_run" --wait 40
[[ -s $work/replacement-uid && ! -e $admin_run/evidence/drained.ticket ]] || fail 'Expected a replacement during eviction'
[[ $(kubectl get pod stable-0 -o jsonpath='{.metadata.uid}{.metadata.deletionTimestamp}') == "$(<"$work/replacement-uid")" ]] || fail 'Eviction deleted the replacement pod'
kubectl delete statefulset stable --cascade=foreground --wait=true
"$cli" cancel --run "$admin_run" --wait 40

kubectl create -f - <<YAML
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: maintenance-agent}
spec:
  selector: {matchLabels: {app: maintenance-agent}}
  updateStrategy: {type: OnDelete}
  template:
    metadata: {labels: {app: maintenance-agent}}
    spec:
      nodeSelector: {kubernetes.io/hostname: "$worker"}
      terminationGracePeriodSeconds: 1
      tolerations:
        - {key: k8s-maintenance/hold, operator: Exists, effect: NoExecute}
        - {key: k8s-maintenance/hold, operator: Equal, value: other, effect: NoSchedule}
      containers:
        - {name: agent, image: "$pause_image", imagePullPolicy: IfNotPresent}
YAML
kubectl wait --for=jsonpath='{.status.numberReady}'=1 daemonset/maintenance-agent --timeout=60s
expect_failure 'persistent worker run directory' docker exec "$worker" "$host_dir/bin/k8s-maintenance" prepare --run /tmp/volatile-maintenance --node "$worker" --ip "$ip" --reboot
expect_failure 'persistent worker filesystem' docker exec "$worker" "$host_dir/bin/k8s-maintenance" prepare --run /dev/shm/volatile-maintenance --node "$worker" --ip "$ip" --reboot
docker exec "$worker" "$host_dir/bin/k8s-maintenance" prepare --run "$host_dir/reboot" --node "$worker" --ip "$ip" --reboot
docker cp "$worker:$host_dir/reboot/evidence/prepared.ticket" "$work/reboot-prepared"
reboot_run="$work/reboot-admin"
"$cli" inspect --run "$reboot_run" --ticket "$work/reboot-prepared" --context "kind-$cluster"
expect_failure 'DaemonSet default/maintenance-agent cannot replace pods' "$cli" drain --run "$reboot_run"
[[ -z $(hold) && -z $(reservation) && ! -e $reboot_run/evidence/drained.ticket ]] || fail 'Reboot drain accepted an incompatible DaemonSet'
compatible='{"spec":{"template":{"spec":{"tolerations":[{"key":"k8s-maintenance/hold","operator":"Exists","effect":"NoSchedule"}]}}}}'
kubectl patch daemonset maintenance-agent --type=merge -p "$compatible"
FAULT=before-hold expect_failure 'Interrupted before placing the hold' "$cli" drain --run "$reboot_run"
uid=$(reservation)
[[ $uid && -z $(hold) ]] || fail 'Expected a reservation without a scheduling hold'
kubectl patch daemonset maintenance-agent --type=merge \
	-p "{\"spec\":{\"template\":{\"spec\":{\"tolerations\":[{\"key\":\"k8s-maintenance/hold\",\"operator\":\"Equal\",\"value\":\"$uid\",\"effect\":\"NoSchedule\"}]}}}}"
FAULT=daemonset-drift expect_failure 'DaemonSet default/maintenance-agent cannot replace pods' "$cli" drain --run "$reboot_run"
[[ -n $(hold) && $(hold) == "$(reservation)" && ! -e $reboot_run/evidence/drained.ticket ]] || fail 'Reboot drain ignored a changed DaemonSet template'
"$cli" cancel --run "$reboot_run" --wait 40
kubectl patch daemonset maintenance-agent --type=merge -p "$compatible"
kubectl taint node "$worker" k8s-maintenance/hold=other:PreferNoSchedule

admin_run="$work/next-admin"
"$cli" inspect --run "$admin_run" --ticket "$work/prepared" --context "kind-$cluster"
"$cli" drain --run "$admin_run" --wait 40
agent=$(kubectl get pod -l app=maintenance-agent -o jsonpath='{.items[0].metadata.name}')
agent_uid=$(kubectl get pod "$agent" -o jsonpath='{.metadata.uid}')
kubectl delete pod "$agent" --wait=true
for ((i = 0; i < 30; i++)); do
	replacement=$(kubectl get pods -l app=maintenance-agent -o name)
	[[ $replacement ]] && break
	sleep 1
done
[[ $replacement ]] || fail 'The DaemonSet did not replace its pod under the hold'
kubectl wait --for=condition=Ready "$replacement" --timeout=60s
[[ $(kubectl get "$replacement" -o jsonpath='{.metadata.uid}') != "$agent_uid" && -n $(hold) ]] || fail 'Expected a Ready replacement DaemonSet pod under the hold'
docker cp "$admin_run/evidence/drained.ticket" "$worker:$host_dir/drained"
manifest="$host_dir/run/evidence/maintenance-scripts.sha256"
docker exec "$worker" cp "$manifest" "$manifest.saved"
docker exec "$worker" sed -i '2d' "$manifest"
expect_failure 'checksum file changed' host apply --ticket "$host_dir/drained"
docker exec "$worker" test ! -e "$host_dir/attempts" || fail 'Action ran with a missing checksum'
docker exec "$worker" test ! -e "$host_dir/run/evidence/verified.ticket" || fail 'Verification ticket issued before apply'
docker exec "$worker" cp "$manifest.saved" "$manifest"
host apply --ticket "$host_dir/drained"
docker cp "$worker:$host_dir/run/evidence/verified.ticket" "$work/verified"

uid=$(reservation)
expect_failure 'unique by key and effect' kubectl patch node "$worker" --dry-run=server --type=json \
	-p '[{"op":"add","path":"/spec/taints/-","value":{"key":"k8s-maintenance/hold","effect":"NoSchedule","value":"foreign"}}]'
FAULT=ambiguous-hold expect_failure 'Multiple maintenance holds' "$cli" return --run "$admin_run" --ticket "$work/verified" --wait 40
[[ $(hold) == "$uid" && $(reservation) == "$uid" ]] || fail 'Return removed an ambiguous hold'
FAULT=pending expect_failure 'Cluster health changed before releasing' "$cli" return --run "$admin_run" --ticket "$work/verified" --wait 40
[[ -n $uid && $(hold) == "$uid" && $(reservation) == "$uid" ]] || fail 'Return released an unhealthy worker'
kubectl delete pod unplaceable --wait=true
sed "s/$uid/00000000-0000-0000-0000-000000000001/g" "$work/verified" >"$work/previous-drain"
expect_failure 'does not belong' "$cli" return --run "$admin_run" --ticket "$work/previous-drain"
kubectl taint node "$worker" k8s-maintenance/hold=another-run:NoSchedule --overwrite
expect_failure 'no longer owns' "$cli" return --run "$admin_run" --ticket "$work/verified" --wait 40
[[ $(hold) == another-run && $(reservation) == "$uid" ]] || fail 'Return removed another hold'
kubectl taint node "$worker" "k8s-maintenance/hold=$uid:NoSchedule" --overwrite
FAULT=patch-conflict expect_failure 'invalid' "$cli" return --run "$admin_run" --ticket "$work/verified" --wait 40
[[ $(scheduling) == cordoned && $(hold) == "$uid" && $(reservation) == "$uid" ]] || fail 'Return ignored a concurrent node change'
FAULT=lock-conflict expect_failure 'Conflict' "$cli" return --run "$admin_run" --ticket "$work/verified" --wait 40
expect_failure 'Reservation ownership changed' "$cli" return --run "$admin_run" --ticket "$work/verified"
[[ $(scheduling) == cordoned && -z $(hold) && $(reservation) == "$uid" ]] || fail 'Return removed a changed reservation or manual cordon'
kubectl -n kube-system patch configmap k8s-maintenance-lock --type=merge -p "{\"data\":{\"admin\":\"$(<"$admin_run/admin-id")\"}}"
"$cli" return --run "$admin_run" --ticket "$work/verified" --wait 40
[[ $(scheduling) == cordoned && -z $(hold) && -z $(reservation) ]] || fail 'Return cleared an external cordon'
[[ $(kubectl get node "$worker" -o jsonpath='{.spec.taints[?(@.key=="audit")].value}') == keep ]] || fail 'Return removed an unrelated taint'
[[ $(kubectl get node "$worker" -o jsonpath='{.spec.taints[?(@.key=="k8s-maintenance/hold")].value}') == other ]] || fail 'Return removed the same key with a different effect'
[[ $(docker exec "$worker" cat "$host_dir/attempts") == ran ]] || fail 'Action ran more than once'
printf 'existing report\n' >"$admin_run-evidence.tar.gz"
archive=$("$cli" archive --run "$admin_run")
again=$("$cli" archive --run "$admin_run")
[[ $archive != "$again" && $(<"$admin_run-evidence.tar.gz") == 'existing report' ]] || fail 'Archive overwrote an existing report'
printf '%s\n' 'PASS scheduling ownership, reservation recovery, eviction and worker action checks'

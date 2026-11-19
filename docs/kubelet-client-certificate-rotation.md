# Kubelet client certificate rotation

Kubelet can renew the client certificate it uses to authenticate to the Kubernetes API. This guide applies to self-managed nodes where you control the kubelet configuration. Kubeadm enables client certificate rotation by default. For managed nodes, use your provider's documentation. [Kubernetes rotation guide](https://kubernetes.io/docs/tasks/tls/certificate-rotation/) · [kubeadm certificate management](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/)

## Enable rotation

1. Identify the kubelet configuration in use and check that the node is `Ready`. If the client credential has expired or the kubeconfig uses an embedded certificate, consult your distribution's recovery guidance first. If the node already uses a managed client certificate and rotation is enabled, skip to verification. [kubeadm troubleshooting](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/troubleshooting-kubeadm/#kubelet-client-certificate-rotation-fails)
2. Confirm your cluster can approve and sign requests for `kubernetes.io/kube-apiserver-client-kubelet` and trusts the resulting client certificates. [Kubelet TLS bootstrapping](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-tls-bootstrapping/)
3. Back up the active kubelet configuration. Set the following field in the existing `KubeletConfiguration` through the same tooling that manages the node. Check for a conflicting command-line flag. [Kubelet configuration reference](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/)

   ```yaml
   rotateCertificates: true
   ```

4. Restart kubelet on one node at a time. For a systemd service, use the command below.

   ```bash
   sudo systemctl restart kubelet
   ```

## Verify

From a working admin context, confirm the node is `Ready` and its pods are healthy before changing another node.

```bash
NODE='worker-1'  # Replace with the name shown by kubectl get nodes.
kubectl wait --for=condition=Ready "node/$NODE" --timeout=180s
kubectl get pods -A --field-selector "spec.nodeName=$NODE"
kubectl get csr -o wide
```

Check that the node's `renewTime` continues to advance by running the following command twice, about 20 seconds apart.

```bash
kubectl -n kube-node-lease get lease "$NODE" -o jsonpath='{.spec.renewTime}{"\n"}'
```

A valid certificate may stay in use until it nears expiry. When renewal occurs, look for an `Approved,Issued` CSR from `system:node:<node-name>` with the kubelet client signer, and confirm that the active certificate's expiry has moved forward. [Kubernetes rotation guide](https://kubernetes.io/docs/tasks/tls/certificate-rotation/)

If the node fails to recover after the configuration change, restore the backed-up configuration, restart kubelet, and recheck the node before continuing.

## Monitor expiry

On the node, inspect the active client certificate. The example path below is the standard kubeadm location. Use the path configured on your node.

```bash
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -enddate
```

If your monitoring system collects kubelet metrics, alert per node on low `kubelet_certificate_manager_client_ttl_seconds` and increases in `kubelet_certificate_manager_client_expiration_renew_errors`. Check that the metrics are present for the nodes you expect to monitor. [Kubernetes metrics reference](https://kubernetes.io/docs/reference/instrumentation/metrics/)

# Kubernetes Worker Maintenance

`k8s-maintenance` is a Bash CLI for maintenance on one Linux Kubernetes worker at a time. It checks cluster health, drains the worker with PodDisruptionBudgets in effect, runs your Bash action, and verifies recovery before removing its own `NoSchedule` taint. It leaves manual cordons intact. You can also request a reboot and supply a Bash check for the work you performed.

Run the worker phases in a shell on the worker and the cluster phases in your Kubernetes admin session. Supply the Kubernetes context, the worker's name and IPv4 InternalIP, and the action for that run. See the [worker maintenance guide](docs/maintenance.md) for permissions, examples and recovery.

```bash
bin/k8s-maintenance --help
```

## Contributing

Run these checks from the repository root when changing the Bash CLI.

```bash
shellcheck -ax bin/k8s-maintenance tests/maintenance-kind.sh
shfmt -d bin/k8s-maintenance hack/utils.bash tests/maintenance-kind.sh
git diff --check
```

Run `tests/maintenance-kind.sh` with Docker, kind and kubectl to exercise failure and recovery on a disposable two-worker cluster. The default node image is `kindest/node:v1.32.8`. Use a matching kubectl client or set `KIND_NODE_IMAGE` to the version you want to test.

## Runbooks

- [Manual RHEL node patching](docs/manual-node-patching.md)
- [Kubelet client certificate rotation](docs/kubelet-client-certificate-rotation.md)

## License

The project uses the MIT license. The shared Bash helpers use [Apache-2.0](LICENSES/Apache-2.0.txt).

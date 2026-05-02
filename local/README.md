# Kind (Kubernetes in Docker)

[Kind](https://kind.sigs.k8s.io/) is a tool for running local Kubernetes clusters using Docker containers as nodes. It was primarily designed for testing Kubernetes itself, but is also useful for local development and CI.

## Installation

### Linux

```bash
curl -Lo ./kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
```

### macOS

```bash
brew install kind
```

### Windows

```powershell
choco install kind
```

## Usage

### Create a cluster

Using the provided configuration:

```bash
kind create cluster --config kind.yaml
```

This creates a cluster with one control-plane node and two worker nodes as defined in `kind.yaml`.

### Interact with the cluster

Kind automatically sets your kubeconfig context. Use `kubectl` as normal:

```bash
kubectl get nodes
kubectl cluster-info
```

### Delete the cluster

```bash
kind delete cluster
```

### Other useful commands

```bash
kind get clusters        # List running clusters
kind export kubeconfig   # Export kubeconfig for a cluster
```

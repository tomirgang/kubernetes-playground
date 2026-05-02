#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  k3s       Update k3s (Kubernetes) on the cluster
  os        Update MicroOS (rebuild snapshot and reprovision nodes)
  all       Run both k3s and os update

Options:
  -h, --help    Show this help message

Note: This script is designed for single control plane clusters.
      Expect brief downtime during updates.
EOF
  exit 0
}

confirm() {
  read -rp "$1 [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
}

get_k3s_channel() {
  grep -oP 'initial_k3s_channel\s*=\s*"\K[^"]+' kube.tf 2>/dev/null || echo "stable"
}

get_nodes() {
  kubectl get nodes -o jsonpath='{.items[*].metadata.name}'
}

update_k3s() {
  echo "=== k3s (Kubernetes) Update ==="

  local channel
  channel=$(get_k3s_channel)
  echo "Current k3s channel: $channel"
  read -rp "New k3s channel/version (leave empty to keep '$channel'): " new_channel
  new_channel="${new_channel:-$channel}"

  echo ""
  echo "This will update k3s to channel: $new_channel"
  echo "The cluster will be briefly unavailable during the control plane restart."
  confirm "Proceed with k3s update?"

  echo ""
  echo "Fetching node IPs..."
  local cp_ip
  cp_ip=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')

  if [[ -z "$cp_ip" ]]; then
    cp_ip=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  fi

  if [[ -z "$cp_ip" ]]; then
    read -rp "Could not determine control plane IP. Enter manually: " cp_ip
  fi

  echo "Updating k3s on control plane ($cp_ip)..."
  ssh -o StrictHostKeyChecking=accept-new "root@${cp_ip}" \
    "curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=${new_channel} sh -s - server"

  echo ""
  echo "Waiting for control plane to become ready..."
  sleep 10
  kubectl wait --for=condition=Ready nodes -l node-role.kubernetes.io/control-plane --timeout=120s

  echo ""
  echo "Updating k3s on worker nodes..."
  local workers
  workers=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.addresses[?(@.type=="ExternalIP")].address}{"\t"}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')

  while IFS=$'\t' read -r name ext_ip int_ip; do
    [[ -z "$name" ]] && continue
    local worker_ip="${ext_ip:-$int_ip}"
    echo "  Draining $name..."
    kubectl drain "$name" --ignore-daemonsets --delete-emptydir-data --timeout=120s
    echo "  Updating k3s on $name ($worker_ip)..."
    ssh -o StrictHostKeyChecking=accept-new "root@${worker_ip}" \
      "curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=${new_channel} sh -s - agent"
    echo "  Uncordoning $name..."
    kubectl uncordon "$name"
  done <<< "$workers"

  echo ""
  echo "k3s update complete."
  kubectl get nodes -o wide
}

update_os() {
  echo "=== MicroOS Update ==="
  echo ""
  echo "Step 1: Build new MicroOS snapshot"
  read -rp "Build new Packer snapshot now? [y/N]: " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    echo ""
    echo "Deleting old MicroOS snapshots..."
    if command -v hcloud &>/dev/null; then
      hcloud image list --selector 'microos-snapshot=yes' -o columns=id -o noheader | while read -r img_id; do
        [[ -z "$img_id" ]] && continue
        echo "  Deleting snapshot $img_id..."
        hcloud image delete "$img_id"
      done
    else
      echo "  WARNUNG: hcloud CLI nicht verfügbar. Bitte alte Snapshots manuell löschen."
      exit 1
    fi

    echo ""
    packer init hcloud-microos-snapshots.pkr.hcl
    packer build hcloud-microos-snapshots.pkr.hcl
  else
    echo "  Snapshot-Build übersprungen."
  fi

  echo ""
  echo "Step 2: Reprovision nodes with new snapshot"
  echo ""
  echo "Available nodes:"
  kubectl get nodes -o wide
  echo ""

  confirm "Reprovision ALL nodes? (Each node will be drained and recreated)"

  echo ""
  echo "Getting Terraform state..."
  
  # Ensure modules are up to date
  tofu init -upgrade

  local resources
  resources=$(tofu state list | grep 'hcloud_server' || true)

  if [[ -z "$resources" ]]; then
    echo "Error: No hcloud_server resources found in Terraform state."
    exit 1
  fi

  echo "Found resources:"
  echo "$resources"
  echo ""

  # Process control plane first, then workers
  # (Workers need the new control plane's join token)
  local workers cp
  workers=$(echo "$resources" | grep -v control_plane || true)
  cp=$(echo "$resources" | grep control_plane || true)

  for resource in $cp; do
    echo "--- Updating control plane: $resource ---"
    echo "  WARNING: Cluster will be unavailable during control plane reprovision!"
    confirm "  Proceed with control plane reprovision?"
    echo "  Destroying control plane..."
    tofu destroy -auto-approve -target="$resource"
    echo "  Recreating control plane..."
    tofu apply -auto-approve
    echo "  Updating kubeconfig..."
    tofu output --raw kubeconfig > kubeconfig
    export KUBECONFIG="$(pwd)/kubeconfig"
    echo "  Waiting for control plane to become ready..."
    sleep 60
    kubectl wait --for=condition=Ready nodes -l node-role.kubernetes.io/control-plane --timeout=300s
    echo ""
  done

  for resource in $workers; do
    echo "  Destroying worker: $resource"
    tofu destroy -auto-approve -target="$resource"
  done

  echo ""
  echo "  Recreating all workers..."
  tofu apply -auto-approve
  echo "  Waiting for workers to become ready..."
  sleep 30
  kubectl wait --for=condition=Ready nodes -l '!node-role.kubernetes.io/control-plane' --timeout=300s 2>/dev/null || true
  echo ""

  echo "MicroOS update complete."
  kubectl get nodes -o wide
}

# Main
[[ $# -eq 0 ]] && usage

case "${1}" in
  -h|--help)
    usage
    ;;
  k3s)
    update_k3s
    ;;
  os)
    update_os
    ;;
  all)
    update_k3s
    echo ""
    echo "=========================================="
    echo ""
    update_os
    ;;
  *)
    echo "Unknown command: $1"
    usage
    ;;
esac

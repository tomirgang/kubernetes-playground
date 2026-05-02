#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BACKUP_DIR="${SCRIPT_DIR}/.cluster-backup"
MODE_FILE="${BACKUP_DIR}/current-mode"

usage() {
  cat <<EOF
Usage: $(basename "$0") <mode>

Modes:
  normal      1 Control Plane + 2 Worker (~21,55 €/Monat)
  reduziert   1 Control Plane + 0 Worker (~10,35 €/Monat)
  pausiert    Cluster zerstört, Daten lokal gesichert (~0 €/Monat)
  status      Aktuellen Modus anzeigen

Options:
  -h, --help  Hilfe anzeigen
EOF
  exit 0
}

confirm() {
  read -rp "$1 [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Abgebrochen."; exit 1; }
}

get_current_mode() {
  if [[ -f "$MODE_FILE" ]]; then
    cat "$MODE_FILE"
  elif tofu state list &>/dev/null 2>&1 && [[ $(tofu state list 2>/dev/null | wc -l) -gt 0 ]]; then
    # Cluster exists, check worker count
    local count
    count=$(grep -A5 'name.*=.*"worker-nbg1"' kube.tf | grep 'count' | grep -oP '\d+' || echo "0")
    if [[ "$count" -gt 0 ]]; then
      echo "normal"
    else
      echo "reduziert"
    fi
  else
    echo "pausiert"
  fi
}

set_mode() {
  mkdir -p "$BACKUP_DIR"
  echo "$1" > "$MODE_FILE"
}

set_worker_count() {
  local count="$1"
  sed -i -E '/name\s*=\s*"worker-nbg1"/,/count\s*=\s*[0-9]+/ s/(count\s*=\s*)[0-9]+/\1'"$count"'/' kube.tf
}

get_worker_count() {
  grep -A5 'name.*=.*"worker-nbg1"' kube.tf | grep -oP 'count\s*=\s*\K\d+'
}

update_kubeconfig() {
  echo "  Generiere kubeconfig..."
  if ! tofu output --raw kubeconfig > kubeconfig 2>/dev/null; then
    echo "  FEHLER: kubeconfig konnte nicht generiert werden."
    echo "  Manuell ausführen: tofu output --raw kubeconfig > kubeconfig"
    return 1
  fi
  if [[ ! -s kubeconfig ]]; then
    echo "  FEHLER: kubeconfig ist leer."
    return 1
  fi
  export KUBECONFIG="${SCRIPT_DIR}/kubeconfig"
  echo "  kubeconfig aktualisiert: ${SCRIPT_DIR}/kubeconfig"
}

# --- Backup ---

backup_cluster_data() {
  echo "=== Cluster-Daten sichern ==="
  mkdir -p "$BACKUP_DIR"

  # 1. Terraform State
  echo "  Sichere Terraform State..."
  if [[ -f terraform.tfstate ]]; then
    cp terraform.tfstate "$BACKUP_DIR/terraform.tfstate"
  fi
  if [[ -f terraform.tfstate.backup ]]; then
    cp terraform.tfstate.backup "$BACKUP_DIR/terraform.tfstate.backup"
  fi

  # 2. Kubeconfig
  echo "  Sichere Kubeconfig..."
  if [[ -f kubeconfig ]]; then
    cp kubeconfig "$BACKUP_DIR/kubeconfig"
  fi

  # 3. Kubernetes Ressourcen exportieren
  echo "  Exportiere Kubernetes-Ressourcen..."
  if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
    # Alle Namespaces
    kubectl get namespaces -o yaml > "$BACKUP_DIR/namespaces.yaml" 2>/dev/null || true

    # User-Deployments, Services, ConfigMaps, Secrets, PVCs (ohne system-namespaces)
    local namespaces
    namespaces=$(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -v '^kube-' | grep -v '^default$' || true)
    # Include default namespace too
    namespaces="default ${namespaces}"

    for ns in $namespaces; do
      local ns_dir="$BACKUP_DIR/manifests/$ns"
      mkdir -p "$ns_dir"
      for resource in deployments services configmaps secrets persistentvolumeclaims ingresses statefulsets daemonsets cronjobs; do
        kubectl get "$resource" -n "$ns" -o yaml > "$ns_dir/${resource}.yaml" 2>/dev/null || true
      done
    done
    echo "  Kubernetes-Ressourcen exportiert."
  else
    echo "  WARNUNG: kubectl nicht erreichbar, überspringe K8s-Export."
  fi

  # 4. Hetzner Volume Snapshots
  echo "  Erstelle Hetzner Volume Snapshots..."
  if command -v hcloud &>/dev/null; then
    local volumes
    volumes=$(hcloud volume list -o columns=id,name -o noheader 2>/dev/null || true)
    if [[ -n "$volumes" ]]; then
      echo "$volumes" > "$BACKUP_DIR/volumes.txt"
      while IFS=$'\t' read -r vol_id vol_name; do
        vol_id=$(echo "$vol_id" | xargs)
        vol_name=$(echo "$vol_name" | xargs)
        [[ -z "$vol_id" ]] && continue
        echo "    Snapshot für Volume $vol_name (ID: $vol_id)..."
        local snapshot_desc="cluster-backup-$(date +%Y%m%d-%H%M%S)"
        local snapshot_id
        snapshot_id=$(hcloud volume create-snapshot "$vol_id" --description "$snapshot_desc" -o columns=id -o noheader 2>/dev/null || echo "")
        if [[ -n "$snapshot_id" ]]; then
          echo "${vol_id}|${vol_name}|${snapshot_id}|${snapshot_desc}" >> "$BACKUP_DIR/volume-snapshots.txt"
          echo "    Snapshot erstellt: $snapshot_id"
        else
          echo "    WARNUNG: Snapshot für Volume $vol_id fehlgeschlagen."
        fi
      done <<< "$volumes"
    else
      echo "  Keine Volumes gefunden."
    fi
  else
    echo "  WARNUNG: hcloud CLI nicht verfügbar, überspringe Volume Snapshots."
  fi

  echo "  Backup abgeschlossen: $BACKUP_DIR"
}

# --- Restore ---

restore_cluster_data() {
  echo "=== Cluster-Daten wiederherstellen ==="

  if [[ ! -d "$BACKUP_DIR" ]]; then
    echo "  Kein Backup gefunden unter $BACKUP_DIR"
    return 0
  fi

  # 1. Warte auf Cluster-Readiness
  echo "  Warte auf Cluster-Readiness..."
  local retries=30
  while ! kubectl get nodes &>/dev/null 2>&1 && [[ $retries -gt 0 ]]; do
    sleep 10
    retries=$((retries - 1))
  done

  if ! kubectl get nodes &>/dev/null 2>&1; then
    echo "  FEHLER: Cluster nicht erreichbar. Manuelle Wiederherstellung nötig."
    return 1
  fi

  # 2. Kubernetes Ressourcen wiederherstellen
  if [[ -d "$BACKUP_DIR/manifests" ]]; then
    echo "  Stelle Kubernetes-Ressourcen wieder her..."
    for ns_dir in "$BACKUP_DIR/manifests"/*/; do
      local ns
      ns=$(basename "$ns_dir")

      # Namespace erstellen falls nötig
      if [[ "$ns" != "default" ]]; then
        kubectl create namespace "$ns" 2>/dev/null || true
      fi

      # Ressourcen in der richtigen Reihenfolge anwenden
      for resource in configmaps secrets persistentvolumeclaims deployments statefulsets daemonsets services ingresses cronjobs; do
        local file="$ns_dir/${resource}.yaml"
        if [[ -f "$file" ]] && [[ -s "$file" ]]; then
          local items
          items=$(grep -c '^\s*- apiVersion:' "$file" 2>/dev/null || echo "0")
          if [[ "$items" -gt 0 ]] || grep -q 'kind:' "$file" 2>/dev/null; then
            kubectl apply -f "$file" -n "$ns" 2>/dev/null || true
          fi
        fi
      done
    done
    echo "  Kubernetes-Ressourcen wiederhergestellt."
  fi

  echo "  Wiederherstellung abgeschlossen."
}

# --- Mode Transitions ---

to_normal() {
  local current
  current=$(get_current_mode)

  case "$current" in
    normal)
      echo "Cluster ist bereits im Modus 'normal'."
      return 0
      ;;
    reduziert)
      echo "Wechsel: reduziert → normal"
      confirm "Worker-Count auf 2 setzen?"
      set_worker_count 2
      tofu apply
      set_mode "normal"
      echo "Cluster läuft im Modus 'normal'."
      ;;
    pausiert)
      echo "Wechsel: pausiert → normal"
      confirm "Cluster neu aufbauen und Daten wiederherstellen?"
      set_worker_count 2
      tofu apply
      update_kubeconfig
      restore_cluster_data
      set_mode "normal"
      echo "Cluster läuft im Modus 'normal'."
      ;;
  esac
}

to_reduziert() {
  local current
  current=$(get_current_mode)

  case "$current" in
    reduziert)
      echo "Cluster ist bereits im Modus 'reduziert'."
      return 0
      ;;
    normal)
      echo "Wechsel: normal → reduziert"
      confirm "Worker-Nodes herunterfahren? Workloads werden auf den CP verschoben oder gestoppt."

      # Drain workers
      echo "Draining Worker-Nodes..."
      local workers
      workers=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
      for node in $workers; do
        echo "  Drain $node..."
        kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=120s 2>/dev/null || true
      done

      set_worker_count 0
      tofu apply
      set_mode "reduziert"
      echo "Cluster läuft im Modus 'reduziert'."
      ;;
    pausiert)
      echo "Wechsel: pausiert → reduziert"
      confirm "Cluster mit CP-only aufbauen und Daten wiederherstellen?"
      set_worker_count 0
      tofu apply
      update_kubeconfig
      restore_cluster_data
      set_mode "reduziert"
      echo "Cluster läuft im Modus 'reduziert'."
      ;;
  esac
}

to_pausiert() {
  local current
  current=$(get_current_mode)

  if [[ "$current" == "pausiert" ]]; then
    echo "Cluster ist bereits im Modus 'pausiert'."
    return 0
  fi

  echo "Wechsel: $current → pausiert"
  echo ""
  echo "WARNUNG: Das Cluster wird komplett zerstört!"
  echo "Folgende Daten werden vorher gesichert:"
  echo "  - Terraform State"
  echo "  - Kubeconfig"
  echo "  - Kubernetes-Ressourcen (Deployments, Services, etc.)"
  echo "  - Hetzner Volume Snapshots"
  echo ""
  confirm "Fortfahren?"

  # Kubeconfig setzen falls vorhanden
  if [[ -f kubeconfig ]]; then
    export KUBECONFIG="${SCRIPT_DIR}/kubeconfig"
  fi

  backup_cluster_data
  echo ""

  echo "Zerstöre Cluster..."
  tofu destroy

  set_mode "pausiert"
  echo ""
  echo "Cluster pausiert. Backups unter: $BACKUP_DIR"
}

show_status() {
  local mode
  mode=$(get_current_mode)
  local worker_count
  worker_count=$(get_worker_count)

  echo "=== Cluster Status ==="
  echo "Modus:        $mode"
  echo "Worker Count: $worker_count (in kube.tf)"

  case "$mode" in
    normal)
      echo "Kosten:       ~21,55 €/Monat"
      ;;
    reduziert)
      echo "Kosten:       ~10,35 €/Monat"
      ;;
    pausiert)
      echo "Kosten:       ~0 €/Monat"
      if [[ -d "$BACKUP_DIR" ]]; then
        echo "Backup:       $BACKUP_DIR"
        if [[ -f "$BACKUP_DIR/volume-snapshots.txt" ]]; then
          echo "Snapshots:    $(wc -l < "$BACKUP_DIR/volume-snapshots.txt") Volume-Snapshot(s)"
        fi
      fi
      ;;
  esac

  if [[ "$mode" != "pausiert" ]]; then
    echo ""
    if kubectl get nodes &>/dev/null 2>&1; then
      kubectl get nodes -o wide 2>/dev/null
    else
      echo "(Cluster nicht erreichbar)"
    fi
  fi
}

# --- Main ---

[[ $# -eq 0 ]] && usage

case "${1}" in
  -h|--help)   usage ;;
  normal)      to_normal ;;
  reduziert)   to_reduziert ;;
  pausiert)    to_pausiert ;;
  status)      show_status ;;
  *)
    echo "Unbekannter Modus: $1"
    usage
    ;;
esac

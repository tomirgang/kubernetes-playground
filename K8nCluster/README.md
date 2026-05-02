# K8nCluster – Kubernetes auf Hetzner Cloud

Dieses Setup erstellt ein kleines Kubernetes-Cluster auf Hetzner Cloud mithilfe von [terraform-hcloud-kube-hetzner](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner) (k3s-basiert).

## Cluster-Übersicht

| Komponente       | Typ / Größe | Anzahl | Kosten (ca.)  |
|------------------|-------------|--------|---------------|
| Control Plane    | CX22        | 1      | ~4,35 €/Monat |
| Worker Node      | CX22        | 2      | ~8,70 €/Monat |
| Load Balancer    | LB11        | 1      | ~6,00 €/Monat |
| Volume           | 50 GB       | 1      | ~2,50 €/Monat |
| **Gesamt**       |             |        | **~21,55 €/Monat** |

## Voraussetzungen

- [Terraform](https://www.terraform.io/) oder [OpenTofu](https://opentofu.org/)
- [Packer](https://www.packer.io/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [hcloud CLI](https://github.com/hetznercloud/cli)
- Ein Hetzner Cloud Projekt mit API-Token (Read & Write)
- SSH-Schlüsselpaar unter `~/.ssh/id_ed25519`

## Schritt-für-Schritt-Anleitung

### 1. Hetzner API-Token setzen

```bash
export TF_VAR_hcloud_token="dein-hcloud-api-token"
export HCLOUD_TOKEN="$TF_VAR_hcloud_token"
```

### 2. Projekt-Dateien generieren (falls noch nicht geschehen)

Das Skript von kube-hetzner erstellt die Ausgangsdateien `kube.tf` und `hcloud-microos-snapshots.pkr.hcl`:

```bash
tmp_script=$(mktemp) && \
  curl -sSL -o "${tmp_script}" https://raw.githubusercontent.com/kube-hetzner/terraform-hcloud-kube-hetzner/master/scripts/create.sh && \
  chmod +x "${tmp_script}" && "${tmp_script}" && rm "${tmp_script}"
```

### 3. `kube.tf` anpassen

Die Nodepools in `kube.tf` für 1 Master + 2 Worker (CX22) konfigurieren:

```hcl
control_plane_nodepools = [
  {
    name        = "control-plane-nbg1"
    server_type = "cx22"
    location    = "nbg1"
    labels      = []
    taints      = []
    count       = 1
  }
]

agent_nodepools = [
  {
    name        = "worker-nbg1"
    server_type = "cx22"
    location    = "nbg1"
    labels      = []
    taints      = []
    count       = 2
  }
]
```

Load Balancer:

```hcl
load_balancer_type     = "lb11"
load_balancer_location = "nbg1"
```

### 4. MicroOS-Snapshot erstellen

Packer baut das Basis-Image (openSUSE MicroOS) auf Hetzner:

```bash
packer init hcloud-microos-snapshots.pkr.hcl
packer build hcloud-microos-snapshots.pkr.hcl
```

### 5. Cluster provisionieren

```bash
tofu init
tofu plan
tofu apply
```

Nach erfolgreichem Apply wird automatisch eine `kubeconfig`-Datei erzeugt.

### 6. kubeconfig einrichten

```bash
export KUBECONFIG=$(pwd)/kubeconfig
tofu output --raw kubeconfig > kubeconfig
kubectl get nodes
```

### 7. 50-GB-Volume anlegen und einbinden

Ein Hetzner-Volume kann über die hcloud CLI oder direkt als PersistentVolumeClaim im Cluster genutzt werden (Hetzner CSI ist standardmäßig aktiviert):

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: blog-storage
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
  storageClassName: hcloud-volumes
```

```bash
kubectl apply -f pvc.yaml
```

### 8. Cluster verifizieren

```bash
kubectl get nodes
kubectl get pods -A
kubectl get pvc
```

## Cluster updaten

Da dieses Cluster nur einen Control-Plane-Node hat (kein HA), müssen automatische Upgrades deaktiviert sein:

```hcl
automatically_upgrade_k3s = false
automatically_upgrade_os  = false
```

Updates werden stattdessen manuell über das mitgelieferte Skript `cluster_update.sh` durchgeführt.

### k3s (Kubernetes) updaten

```bash
./cluster_update.sh k3s
```

Das Skript:
1. Fragt nach dem gewünschten k3s-Channel (z.B. `v1.33`, `stable`)
2. Aktualisiert k3s auf dem Control-Plane-Node per SSH
3. Drains und aktualisiert Worker-Nodes nacheinander
4. Wartet auf Node-Readiness nach jedem Update

### MicroOS (Betriebssystem) updaten

```bash
./cluster_update.sh os
```

Das Skript:
1. Baut einen neuen MicroOS-Snapshot mit Packer
2. Drains Worker-Nodes und reprovisiert sie einzeln via `tofu taint` + `tofu apply`
3. Reprovisiert den Control-Plane-Node (kurze Downtime unvermeidbar)

### Beides updaten

```bash
./cluster_update.sh all
```

> **Hinweis:** Bei einem Single-Control-Plane-Cluster ist kurze Downtime während des Updates unvermeidbar. Updates am besten zu einer ruhigen Zeit durchführen.

## Kosten sparen

Hetzner berechnet auch gestoppte Server, da Ressourcen (CPU, RAM, Disk, IP) reserviert bleiben. Das Skript `cluster_mode.sh` ermöglicht es, zwischen drei Betriebsmodi umzuschalten:

| Modus | Beschreibung | Monatliche Kosten |
|-------|-------------|-------------------|
| `normal` | 1 CP + 2 Worker + LB | ~21,55 € |
| `reduziert` | 1 CP + 0 Worker + LB | ~10,35 € |
| `pausiert` | Cluster zerstört, Daten lokal gesichert | ~0 € |

### Modus wechseln

```bash
./cluster_mode.sh normal      # Vollbetrieb
./cluster_mode.sh reduziert   # Nur Control Plane
./cluster_mode.sh pausiert    # Cluster zerstören + Backup
./cluster_mode.sh status      # Aktuellen Modus anzeigen
```

### Was wird bei `pausiert` gesichert?

Beim Wechsel auf `pausiert` sichert das Skript automatisch:

- **Tofu State** (für konsistente Infrastruktur)
- **Kubeconfig**
- **Kubernetes-Ressourcen** (Deployments, Services, ConfigMaps, Secrets, PVCs, Ingresses, etc.)
- **Hetzner Volume Snapshots** (Daten der Persistent Volumes)

Alle Backups werden unter `.cluster-backup/` gespeichert.

Beim Wechsel zurück auf `normal` oder `reduziert` wird das Cluster neu aufgebaut und die gesicherten Ressourcen automatisch wiederhergestellt.

> **Hinweis:** Volume Snapshots verbleiben in Hetzner Cloud und verursachen geringe Kosten (~0,01 €/GB/Monat). Diese können nach erfolgreicher Wiederherstellung manuell gelöscht werden.

## Cluster löschen

```bash
tofu destroy
```

## Nützliche Befehle

```bash
# Nodes auflisten
kubectl get nodes -o wide

# Alle Pods anzeigen
kubectl get pods -A

# Cluster-Info
kubectl cluster-info

# Kubeconfig aus Tofu neu exportieren
tofu output --raw kubeconfig > kubeconfig
```

## GitOps mit Flux

[Flux](https://fluxcd.io/) überwacht dieses Git-Repository und synchronisiert Kubernetes-Manifeste automatisch ins Cluster. Änderungen werden per `git push` deployed – kein manuelles `kubectl apply` nötig.

### Voraussetzungen

- [Flux CLI](https://fluxcd.io/flux/installation/) (`flux`)
- GitHub Personal Access Token mit `repo`-Rechten

### Flux installieren

```bash
export GITHUB_TOKEN="dein-github-token"

flux bootstrap github \
  --owner=tomirgang \
  --repository=kubernetes-playground \
  --path=flux \
  --branch=main \
  --personal
```

Das erstellt:
- Einen `flux-system`-Namespace mit den Flux-Controllern
- Ein Verzeichnis `flux/` mit der Flux-Konfiguration

### Anwendungen einbinden

Anwendungen werden als `Kustomization`-Ressource definiert, z.B. für Mealie:

```yaml
# K8nCluster/flux/mealie.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: mealie
  namespace: flux-system
spec:
  interval: 5m
  path: ./local/mealie
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  targetNamespace: mealie
```

### Workflow

1. YAML-Manifeste im Repo ändern (z.B. `local/mealie/deployment.yaml`)
2. `git commit && git push`
3. Flux erkennt die Änderung und applied sie automatisch

### Flux-Status prüfen

```bash
# Übersicht aller Flux-Ressourcen
flux get all

# Sync-Status einer Kustomization
flux get kustomizations

# Manuelle Synchronisation erzwingen
flux reconcile kustomization mealie

# Flux-Logs anzeigen
flux logs
```

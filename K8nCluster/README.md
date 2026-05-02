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

## Cluster löschen

```bash
terraform destroy
```

## Nützliche Befehle

```bash
# Nodes auflisten
kubectl get nodes -o wide

# Alle Pods anzeigen
kubectl get pods -A

# Cluster-Info
kubectl cluster-info

# Kubeconfig aus Terraform neu exportieren
terraform output --raw kubeconfig > kubeconfig
```

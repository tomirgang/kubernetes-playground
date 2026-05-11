# k3s Cluster auf Hetzner Cloud mit hetzner-k3s

Dieses Setup ersetzt das bisherige Terraform/kube-hetzner-basierte Cluster (`K8nCluster/`) durch ein einfacheres Setup mit [hetzner-k3s](https://github.com/vitobotta/hetzner-k3s). Kein Terraform, kein Packer, kein Ansible — nur ein CLI-Tool und eine YAML-Konfiguration.

## Voraussetzungen

- Ein [Hetzner Cloud](https://www.hetzner.com/cloud) Account
- Ein Hetzner Cloud API Token (erstellt im Hetzner Cloud Console unter **Security → API Tokens**)
- Ein SSH-Schlüsselpaar (`~/.ssh/id_ed25519`)
- `kubectl` installiert

## Schritt 1: hetzner-k3s installieren

### Option A: Homebrew (macOS/Linux)

```bash
brew install vitobotta/tap/hetzner_k3s
```

### Option B: Binary herunterladen (Linux amd64)

```bash
wget https://github.com/vitobotta/hetzner-k3s/releases/latest/download/hetzner-k3s-linux-amd64
chmod +x hetzner-k3s-linux-amd64
sudo mv hetzner-k3s-linux-amd64 /usr/local/bin/hetzner-k3s
```

Prüfen ob die Installation erfolgreich war:

```bash
hetzner-k3s version
```

## Schritt 2: Hetzner Cloud API Token erstellen

1. In der [Hetzner Cloud Console](https://console.hetzner.cloud/) einloggen
2. Ein neues Projekt erstellen (z.B. `tomsblog`) oder ein bestehendes auswählen
3. Unter **Security → API Tokens → Generate API Token** einen neuen Token mit **Read & Write** Berechtigung erstellen
4. Den Token sicher aufbewahren (z.B. in einem Passwort-Manager)

## Schritt 3: Cluster-Konfiguration erstellen

Die Datei `cluster.yaml` in diesem Verzeichnis anlegen:

```yaml
---
hetzner_token: <DEIN_HETZNER_TOKEN>
cluster_name: tomsblog
kubeconfig_path: "./kubeconfig"
k3s_version: v1.33.1+k3s1

networking:
  ssh:
    port: 22
    use_agent: false
    public_key_path: "~/.ssh/id_ed25519.pub"
    private_key_path: "~/.ssh/id_ed25519"
  allowed_networks:
    ssh:
      - 0.0.0.0/0
    api:
      - 0.0.0.0/0
  public_network:
    ipv4: true
    ipv6: true
  private_network:
    enabled: true
    subnet: 10.0.0.0/16
    existing_network_name: ""
  cni:
    enabled: true
    encryption: false
    mode: flannel

schedule_workloads_on_masters: false

masters_pool:
  instance_type: cpx22
  instance_count: 1
  location: nbg1

worker_node_pools:
- name: workers
  instance_type: cpx22
  instance_count: 2
  location: nbg1

protect_against_deletion: true
create_load_balancer_for_the_kubernetes_api: false
```

> **Hinweis:** Den Hetzner Token kann man alternativ über die Umgebungsvariable `HCLOUD_TOKEN` setzen, statt ihn in die Datei zu schreiben. So kann die `cluster.yaml` sicher ins Repository eingecheckt werden — einfach `hetzner_token:` leer lassen.

> **Hinweis:** Verfügbare k3s-Versionen anzeigen: `hetzner-k3s releases`

### Konfiguration im Detail

| Einstellung | Wert | Beschreibung |
|---|---|---|
| `cluster_name` | `tomsblog` | Name des Clusters (wie bisher) |
| `masters_pool.instance_type` | `cpx22` | 2 vCPU, 4 GB RAM, 80 GB Disk (AMD) |
| `masters_pool.instance_count` | `1` | Single Master (kein HA — für Prod auf `3` setzen) |
| `masters_pool.location` | `nbg1` | Nürnberg (wie bisher) |
| `worker_node_pools[0].instance_type` | `cpx22` | 2 vCPU, 4 GB RAM, 80 GB Disk (AMD) |
| `worker_node_pools[0].instance_count` | `2` | 2 Worker-Nodes (wie bisher) |
| `cni.mode` | `flannel` | Standard-CNI von k3s (wie bisher) |

### Geschätzte monatliche Kosten

| Komponente | Kosten |
|---|---|
| 1× CPX22 (Master) | ~9,51 € |
| 2× CPX22 (Worker) | ~19,02 € |
| 1× Load Balancer (LB11, automatisch) | ~5,49 € |
| **Gesamt** | **~34,02 €** |

## Schritt 4: Cluster erstellen

```bash
cd k3s/
export HCLOUD_TOKEN=<DEIN_HETZNER_TOKEN>
hetzner-k3s create --config cluster.yaml | tee create.log
```

Das Cluster ist in ca. 2–3 Minuten bereit. Die kubeconfig wird automatisch als `./kubeconfig` gespeichert.

## Schritt 5: Verbindung zum Cluster testen

```bash
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes
```

Erwartete Ausgabe (ähnlich):

```
NAME                    STATUS   ROLES                  AGE   VERSION
tomsblog-master1        Ready    control-plane,master   2m    v1.33.1+k3s1
tomsblog-workers-pool-worker1   Ready    <none>                 1m    v1.33.1+k3s1
tomsblog-workers-pool-worker2   Ready    <none>                 1m    v1.33.1+k3s1
```

### Kubeconfig in ~/.kube/config integrieren

```bash
cp "$KUBECONFIG" ~/.kube/config
# oder mit mehreren Kontexten mergen:
KUBECONFIG=~/.kube/config:$(pwd)/kubeconfig kubectl config view --flatten > ~/.kube/config.merged
mv ~/.kube/config.merged ~/.kube/config
```

## Schritt 6: Flux & Cert-Manager deployen

Wie bisher können Flux und Cert-Manager auf dem neuen Cluster installiert werden. Die bestehenden Flux-Manifeste im `flux/`-Ordner sind weiterhin nutzbar:

```bash
# Flux CLI installieren (falls noch nicht vorhanden)
curl -s https://fluxcd.io/install.sh | sudo bash

# Flux bootstrap (Beispiel mit GitHub)
flux bootstrap github \
  --owner=<GITHUB_USER> \
  --repository=kubernetes-playground \
  --path=flux \
  --personal
```

## Cluster verwalten

### Cluster-Status prüfen

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

### k3s-Version upgraden

Die `k3s_version` in `cluster.yaml` auf die neue Version ändern und dann:

```bash
hetzner-k3s upgrade --config cluster.yaml | tee upgrade.log
```

### Worker-Nodes skalieren

Die `instance_count` im Worker-Pool in `cluster.yaml` anpassen und:

```bash
hetzner-k3s create --config cluster.yaml
```

> Der `create`-Befehl ist idempotent und kann beliebig oft ausgeführt werden.

### Cluster löschen

```bash
hetzner-k3s delete --config cluster.yaml
```

> **Achtung:** `protect_against_deletion: true` verhindert versehentliches Löschen. Zum Löschen zuerst auf `false` setzen.

## Unterschiede zum alten K8nCluster-Setup

| | K8nCluster (alt) | k3s (neu) |
|---|---|---|
| **Tool** | Terraform + kube-hetzner Modul | hetzner-k3s CLI |
| **OS** | openSUSE MicroOS (Packer-Snapshot) | Ubuntu 24.04 (Standard) |
| **Komplexität** | Terraform + Packer + HCL-Kenntnisse | 1 YAML-Datei + 1 CLI-Befehl |
| **Setup-Zeit** | 15–30 Min | 2–3 Min |
| **Abhängigkeiten** | OpenTofu, Packer | Nur hetzner-k3s Binary |
| **Automatische Komponenten** | Manuell konfiguriert | CCM, CSI, System Upgrade Controller inklusive |
| **Cluster Autoscaler** | Nicht konfiguriert | Optional aktivierbar |

## Weiterführende Links

- [hetzner-k3s Dokumentation](https://vitobotta.github.io/hetzner-k3s/)
- [Cluster erstellen (Referenz)](https://vitobotta.github.io/hetzner-k3s/Creating_a_cluster/)
- [Cluster Wartung](https://vitobotta.github.io/hetzner-k3s/Maintenance/)
- [Troubleshooting](https://vitobotta.github.io/hetzner-k3s/Troubleshooting/)
- [Empfehlungen für Produktion](https://vitobotta.github.io/hetzner-k3s/Recommendations/)

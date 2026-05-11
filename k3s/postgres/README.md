# CloudNativePG Operator

Dieses Verzeichnis enthält die Konfiguration für die **Operator-Installation** als Plattform-Voraussetzung.
Die konkreten PostgreSQL-Cluster-Definitionen (DB-Instanzen für Anwendungen) liegen im jeweiligen
Anwendungs-Repository (z.B. `tomsblog/infra/k8s/postgres/`).

## Operator installieren

```bash
kubectl apply -f cnpg-namespace.yaml
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.26/releases/cnpg-1.26.0.yaml
```

Warten bis der Operator läuft:

```bash
kubectl wait --for=condition=Available deployment/cnpg-controller-manager \
  -n cnpg-system --timeout=120s
```

## Status prüfen

```bash
kubectl get pods -n cnpg-system
kubectl get crds | grep cnpg
```

## Nächste Schritte

Nach der Operator-Installation können PostgreSQL-Cluster-Instanzen aus den Anwendungs-Repositories
deployed werden:

```bash
# Beispiel: Blog-Datenbank aus dem tomsblog-Repository
kubectl apply -f <tomsblog-repo>/infra/k8s/postgres/namespace.yaml
kubectl apply -f <tomsblog-repo>/infra/k8s/postgres/cluster.yaml
```
- **User/DB:** aus Secret `postgres-cluster-app`

## Konfiguration

- **Instanzen:** 1 (Single-Node, passend zu 2 Worker-Nodes)
- **Storage:** 10 Gi auf `hcloud-volumes` (Hetzner CSI)
- **Ressourcen:** 512Mi–1Gi RAM, 250m–1000m CPU

### Storage vergrößern

```bash
kubectl patch cluster postgres-cluster -n postgres --type merge \
  -p '{"spec":{"storage":{"size":"20Gi"}}}'
```

> **Hinweis:** Hetzner Volumes können nur vergrößert, nicht verkleinert werden.

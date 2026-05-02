# kubernetes-playground

A playground for experimenting with Kubernetes and related infrastructure tooling.

## Tools

### Terraform

[Terraform](https://www.terraform.io/) is an infrastructure-as-code tool by HashiCorp that lets you define cloud and on-premises resources in declarative configuration files. It manages the full lifecycle of infrastructure using providers for virtually every platform.

#### Usage

```bash
terraform init      # Initialize working directory and download providers
terraform plan      # Preview changes before applying
terraform apply     # Create or update infrastructure
terraform destroy   # Tear down managed infrastructure
```

---

### OpenTofu

[OpenTofu](https://opentofu.org/) is an open-source fork of Terraform, maintained by the Linux Foundation. It is a drop-in replacement offering the same workflow and configuration language (HCL) with a community-driven governance model.

#### Usage

```bash
tofu init      # Initialize working directory
tofu plan      # Preview changes
tofu apply     # Apply infrastructure changes
tofu destroy   # Destroy managed resources
```

---

### Packer

[Packer](https://www.packer.io/) is a tool for building identical machine images for multiple platforms from a single source configuration. It automates the creation of VM images, container images, and cloud AMIs.

#### Usage

```bash
packer init .          # Install required plugins
packer validate .      # Validate the template
packer build .         # Build the image
```

---

### kubectl

[kubectl](https://kubernetes.io/docs/reference/kubectl/) is the command-line tool for interacting with Kubernetes clusters. It allows you to deploy applications, inspect resources, and manage cluster operations.

#### Usage

```bash
kubectl get nodes                  # List cluster nodes
kubectl get pods -A                # List all pods across namespaces
kubectl apply -f manifest.yaml     # Apply a resource manifest
kubectl logs <pod>                 # View pod logs
kubectl exec -it <pod> -- sh       # Open a shell in a pod
kubectl config use-context <ctx>   # Switch cluster context
```

---

### hcloud

[hcloud](https://github.com/hetznercloud/cli) is the CLI for Hetzner Cloud. It allows you to create and manage servers, networks, load balancers, and other resources on the Hetzner Cloud platform.

#### Usage

```bash
hcloud server list                        # List all servers
hcloud server create --name my-server \
  --type cx22 --image ubuntu-24.04        # Create a server
hcloud server delete <id>                 # Delete a server
hcloud network list                       # List networks
hcloud ssh-key list                       # List SSH keys
```

---

### Helm

[Helm](https://helm.sh/) is the package manager for Kubernetes. It uses charts—pre-configured packages of Kubernetes resources—to simplify deploying and managing applications on a cluster.

#### Usage

```bash
helm repo add <name> <url>         # Add a chart repository
helm repo update                   # Update repository index
helm search repo <keyword>         # Search for charts
helm install <release> <chart>     # Install a chart
helm upgrade <release> <chart>     # Upgrade a release
helm uninstall <release>           # Remove a release
helm list                          # List installed releases
```

# Deployment Patterns

Reference material for the TAS Integrator scanner. Documents Trusted Artifact
Signer deployment methods, prerequisites, and component architecture for
OpenShift operator and RHEL Ansible deployments.

---

## Deployment Methods Overview

| Method | Target Platform | Managed By | Package |
|--------|----------------|------------|---------|
| OpenShift Operator | OpenShift 4.x | OLM / Securesign CR | `securesign-operator` |
| Ansible Collection | RHEL 9+ (single node) | Ansible / Podman | `redhat.artifact_signer` |

---

## OpenShift Operator Deployment

### Prerequisites

| Requirement | Details |
|-------------|---------|
| OpenShift version | 4.12+ |
| Cluster admin access | Required for CRD installation |
| OLM (Operator Lifecycle Manager) | Pre-installed on OpenShift |
| Pull secret | Access to `registry.redhat.io` |
| Namespace | Dedicated namespace for TAS (e.g., `trusted-artifact-signer`) |
| OIDC provider | Keycloak, RHBK, or external OIDC (configured separately) |

### Installation Steps

1. **Install the operator from OperatorHub:**

```bash
# Create namespace
kubectl create namespace trusted-artifact-signer

# Subscribe to the operator (via OperatorHub UI or CLI)
cat <<EOF | kubectl apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: securesign-operator
  namespace: openshift-operators
spec:
  channel: stable
  name: securesign-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

2. **Create a Securesign custom resource:**

```yaml
apiVersion: rhtas.redhat.com/v1alpha1
kind: Securesign
metadata:
  name: securesign
  namespace: trusted-artifact-signer
spec:
  rekor: {}
  fulcio:
    config:
      OIDCIssuers:
        - Issuer: "https://{{keycloak_host}}/realms/{{realm_name}}"
          IssuerURL: "https://{{keycloak_host}}/realms/{{realm_name}}"
          ClientID: "trusted-artifact-signer"
          Type: "email"
  trillian: {}
  tuf: {}
  ctlog: {}
  tsa: {}
```

3. **Wait for all components to become ready:**

```bash
kubectl wait --for=condition=Ready securesign/securesign \
  -n trusted-artifact-signer --timeout=300s
```

### Operator CRD Structure

The operator manages the full TAS stack through a single `Securesign` CR:

```go
type SecuresignSpec struct {
    Rekor              RekorSpec
    Fulcio             FulcioSpec
    Trillian           TrillianSpec
    Tuf                TufSpec
    Ctlog              CTlogSpec
    TimestampAuthority *TimestampAuthoritySpec
}
```

Each component can be individually configured or left with defaults. The
operator handles:
- Certificate generation and rotation
- TUF root initialization
- Component interconnection (CT Log ↔ Fulcio, Trillian ↔ Rekor)
- Route/Ingress creation for external access

### Operator-Managed Components

| Component | Pods Created | External Route |
|-----------|-------------|----------------|
| Fulcio | `fulcio-server` | `fulcio-server-<namespace>.apps.<domain>` |
| Rekor | `rekor-server`, `rekor-redis` | `rekor-server-<namespace>.apps.<domain>` |
| Trillian | `trillian-logserver`, `trillian-logsigner`, `trillian-db` | None (internal) |
| CT Log | `ctlog` | None (internal) |
| TUF | `tuf` | `tuf-<namespace>.apps.<domain>` |
| TSA | `tsa-server` | `tsa-server-<namespace>.apps.<domain>` |

### Endpoint Discovery After Deployment

```bash
# From the Securesign CR status
FULCIO_URL=$(kubectl get securesign -n {{namespace}} \
  -o jsonpath='{.items[0].status.fulcio.url}')
REKOR_URL=$(kubectl get securesign -n {{namespace}} \
  -o jsonpath='{.items[0].status.rekor.url}')
TUF_URL=$(kubectl get securesign -n {{namespace}} \
  -o jsonpath='{.items[0].status.tuf.url}')
TSA_URL=$(kubectl get securesign -n {{namespace}} \
  -o jsonpath='{.items[0].status.tsa.url}')
```

---

## RHEL Ansible Deployment

### Prerequisites

| Requirement | Details |
|-------------|---------|
| RHEL version | 9.x |
| Architecture | x86_64 or aarch64 |
| Root access | Required for package installation and systemd |
| Podman | Installed automatically (via `tas_single_node_system_packages`) |
| Registry access | Pull secret for `registry.redhat.io` |
| DNS / hostname | Resolvable hostname for TLS certificates |
| OIDC provider | External OIDC issuer (e.g., Keycloak) pre-configured |

### System Packages

The Ansible collection installs these system packages automatically:

```yaml
tas_single_node_system_packages:
  - podman
  - podman-plugins
  - firewalld
```

### Ansible Collection Installation

```bash
ansible-galaxy collection install redhat.artifact_signer
```

### Playbook Structure

```yaml
- hosts: tas_single_node
  become: true
  roles:
    - role: redhat.artifact_signer.tas_single_node
      vars:
        tas_single_node_base_hostname: "tas.example.com"
        tas_single_node_registry_username: "{{ registry_username }}"
        tas_single_node_registry_password: "{{ registry_password }}"
        tas_single_node_fulcio:
          fulcio_config:
            oidc_issuers:
              - issuer: "https://keycloak.example.com/realms/trusted-artifact-signer"
                url: "https://keycloak.example.com/realms/trusted-artifact-signer"
                client_id: "trusted-artifact-signer"
                type: "email"
            meta_issuers: []
            ci_issuer_metadata: []
```

### Component Architecture (Podman-Based)

All components run as Podman containers managed by systemd:

| Component | Pod Name | Port | Protocol |
|-----------|----------|------|----------|
| Fulcio | `fulcio-server` | 5555 (HTTP), 5554 (gRPC) | HTTPS via nginx |
| Rekor | `rekor-server` | 3001 | HTTPS via nginx |
| Rekor Redis | `rekor-redis` | 6379 | TCP (internal) |
| Trillian Log Server | `trillian-logserver` | 8091 (RPC) | gRPC (internal) |
| Trillian Log Signer | `trillian-logsigner` | 8093 (RPC) | gRPC (internal) |
| Trillian MySQL | `trillian-mysql` | 3306 | TCP (internal) |
| CT Log | `ctlog` | 6962 | HTTP (internal) |
| TUF | `tuf` | 8080 | HTTPS via nginx |
| TSA | `tsa-server` | 3002 | HTTPS via nginx |
| nginx | `nginx` | 443 (HTTPS), 80 (HTTP) | TLS termination |

### Directory Structure on RHEL

```
/etc/rhtas/                        # Config root
├── certs/                         # TLS and signing certificates
│   ├── rhtas.pem                  # Root CA certificate
│   ├── rhtas.key                  # Root CA private key
│   ├── fulcio.pem                 # Fulcio root CA
│   ├── fulcio.key                 # Fulcio private key
│   ├── rekor-pub-key0.pub         # Rekor public key
│   ├── ctlog0.pub                 # CT Log public key
│   └── tsa-cert-chain.pem         # TSA certificate chain
├── configs/                       # Component configuration files
│   ├── fulcio-config.yaml
│   ├── rekor-server-config.yaml
│   └── nginx-config.yaml
├── manifests/                     # Podman pod manifests
└── tuf-repo/                      # TUF repository root
```

### Individual Service Control

Each TAS service can be individually enabled or disabled:

| Variable | Default | Description |
|----------|---------|-------------|
| `tas_single_node_fulcio_enabled` | `true` | Enable Fulcio |
| `tas_single_node_rekor_enabled` | `true` | Enable Rekor |
| `tas_single_node_ctlog_enabled` | `true` | Enable CT Log |
| `tas_single_node_tuf_enabled` | `true` | Enable TUF |
| `tas_single_node_tsa_enabled` | `true` | Enable TSA |
| `tas_single_node_trillian_enabled` | `true` | Enable Trillian |
| `tas_single_node_rekor_search_enabled` | `true` | Enable Rekor Search UI |
| `tas_single_node_client_server_enabled` | `true` | Enable CLI server |

---

## Deployment Comparison

| Feature | OpenShift Operator | RHEL Ansible |
|---------|-------------------|--------------|
| Target | OpenShift 4.12+ | RHEL 9+ |
| Container runtime | CRI-O (OpenShift) | Podman |
| Lifecycle management | OLM automatic upgrades | Manual re-run of playbook |
| Networking | OpenShift Routes / Ingress | nginx reverse proxy |
| TLS | Automatic via OpenShift | Managed by nginx + certs role |
| Scaling | Horizontal pod scaling | Single node only |
| Database | Operator-managed | Podman-managed MySQL |
| Certificate rotation | Operator-managed | Manual re-run or cron |
| Multi-tenancy | Namespace isolation | N/A (single node) |

---

## Scanner Detection Rules

When scanning a target environment, the TAS Integrator looks for deployment
indicators:

| Pattern | Indicates |
|---------|-----------|
| `Securesign` CRD on cluster | OpenShift operator deployment |
| `securesign-operator` subscription | Operator installed via OLM |
| `/etc/rhtas/` directory on host | Ansible-deployed TAS |
| Podman pods matching `fulcio-server`, `rekor-server` | Ansible deployment running |
| OpenShift Routes with `fulcio-server`, `rekor-server` | Operator-managed endpoints |
| `tas_single_node` Ansible variables | Ansible deployment configured |
| `registry.redhat.io/rhtas/` image references | RHTAS container images |

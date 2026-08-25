# TAS Endpoint Configuration

Reference material for the TAS Integrator scanner. Documents Trusted Artifact
Signer component endpoint URL patterns, operator CRD status field discovery,
and Fulcio/Rekor/TSA URL formats.

---

## TAS Component Overview

| Component | Purpose | Typical Path Suffix |
|-----------|---------|---------------------|
| Fulcio | OIDC-based certificate authority | `/api/v2/signingCert` |
| Rekor | Transparency log server | `/api/v1/log/entries` |
| Timestamp Authority | RFC 3161 timestamp server | `/api/v1/timestamp` |
| TUF | The Update Framework root distribution | `/root.json` |
| Console | RHTAS web console (UI + API) | N/A (standalone CRD, not in SecuresignSpec) |
| CT Log | Certificate transparency log | N/A (internal to Fulcio) |
| Trillian | Merkle tree log backend | N/A (internal to Rekor) |

---

## Operator CRD Status Fields

The `rhtas.redhat.com/v1` `Securesign` custom resource exposes component
URLs in its status fields. The TAS operator reconciles these URLs after
deployment.

### SecuresignSpec (Desired State)

```go
type SecuresignSpec struct {
    Rekor              RekorSpec               `json:"rekor,omitempty"`
    Fulcio             FulcioSpec              `json:"fulcio"`
    Trillian           TrillianSpec            `json:"trillian,omitempty"`
    Tuf                TufSpec                 `json:"tuf,omitempty"`
    Ctlog              CTlogSpec               `json:"ctlog,omitempty"`
    TimestampAuthority *TimestampAuthoritySpec `json:"tsa,omitempty"`
}
```

JSON tags matter for kubectl: use `{.spec.tsa}` not `{.spec.timestampAuthority}`.
`Fulcio` is the only required field (no `omitempty`).

### SecuresignStatus (Observed State)

```go
type SecuresignStatus struct {
    Conditions   []metav1.Condition     `json:"conditions,omitempty"`
    RekorStatus  SecuresignRekorStatus  `json:"rekor,omitempty"`
    FulcioStatus SecuresignFulcioStatus `json:"fulcio,omitempty"`
    TufStatus    SecuresignTufStatus    `json:"tuf,omitempty"`
    TSAStatus    SecuresignTSAStatus    `json:"tsa,omitempty"`
}
```

### Component Status URL Fields

| Status Type | Field | Description |
|-------------|-------|-------------|
| `SecuresignRekorStatus` | `Url string` | Rekor server base URL |
| `SecuresignFulcioStatus` | `Url string` | Fulcio server base URL |
| `SecuresignTufStatus` | `Url string` | TUF mirror base URL |
| `SecuresignTSAStatus` | `Url string` | Timestamp Authority URL |

### Discovering Endpoint URLs from the Operator

Individual component CRDs are the recommended discovery method (more robust than
the parent Securesign CR, which may not always be present):

```bash
REKOR_URL=$(kubectl get rekor -n {{namespace}} \
  -o jsonpath='{.items[0].status.url}')

FULCIO_URL=$(kubectl get fulcio -n {{namespace}} \
  -o jsonpath='{.items[0].status.url}')

TUF_URL=$(kubectl get tuf -n {{namespace}} \
  -o jsonpath='{.items[0].status.url}')

TSA_URL=$(kubectl get timestampauthority -n {{namespace}} \
  -o jsonpath='{.items[0].status.url}')
```

Alternatively, the parent Securesign CR exposes all URLs:

```bash
kubectl get securesign -n {{namespace}} -o jsonpath='{.items[0].status}'
```

---

## Endpoint URL Formats

### Fulcio

| Format | Example |
|--------|---------|
| OpenShift Route | `https://fulcio-server-<namespace>.apps.<cluster-domain>` |
| Kubernetes Ingress | `https://fulcio.<domain>` |
| Port-forward (dev) | `http://localhost:5555` |
| Public Sigstore | `https://fulcio.sigstore.dev` |

Signing certificate endpoint: `{{fulcio_url}}/api/v2/signingCert`

Health check: `GET {{fulcio_url}}/healthz`

### Rekor

| Format | Example |
|--------|---------|
| OpenShift Route | `https://rekor-server-<namespace>.apps.<cluster-domain>` |
| Kubernetes Ingress | `https://rekor.<domain>` |
| Port-forward (dev) | `http://localhost:3000` |
| Public Sigstore | `https://rekor.sigstore.dev` |

Log entries endpoint: `{{rekor_url}}/api/v1/log/entries`

Health check: `GET {{rekor_url}}/api/v1/log`

### Timestamp Authority (TSA)

**Operator behavior varies by version:**
- **Recent versions:** `TimestampAuthority.status.url` includes the `/api/v1/timestamp` path suffix
- **Older versions:** `TimestampAuthority.status.url` contains only the base URL

All `{{tsa_url}}` references below assume the full endpoint URL (with `/api/v1/timestamp`).

| Format | Example |
|--------|---------|
| Operator status (recommended) | `https://tsa-server-<namespace>.apps.<cluster-domain>/api/v1/timestamp` |
| Port-forward (dev) | `http://localhost:3002/api/v1/timestamp` |

**Backward-compatible detection:**
```bash
TSA_URL=$(kubectl get timestampauthority -n {{namespace}} -o jsonpath='{.items[0].status.url}')
# Append /api/v1/timestamp if not already present (for older operator versions)
[[ -n "$TSA_URL" && "$TSA_URL" != */api/v1/timestamp ]] && TSA_URL="${TSA_URL}/api/v1/timestamp"
```

Timestamp endpoint: `POST {{tsa_url}}`

Health check: `GET {{tsa_url}}/certchain`

### TUF

| Format | Example |
|--------|---------|
| OpenShift Route | `https://tuf-<namespace>.apps.<cluster-domain>` |
| Kubernetes Ingress | `https://tuf.<domain>` |
| Port-forward (dev) | `http://localhost:8080` |

Root metadata: `GET {{tuf_url}}/root.json`

---

## Cosign TUF Initialization

Before signing or verifying against a private TAS instance, cosign must be
initialized with the TAS TUF root. The `--root-checksum` flag prevents MITM
attacks during initialization by verifying root.json integrity.

```bash
# Compute checksum from the versioned root
ROOT_CHECKSUM=$(curl -s "{{tuf_url}}/1.root.json" | sha256sum | awk '{print $1}')

# Initialize with checksum verification
cosign initialize \
  --mirror="{{tuf_url}}" \
  --root="{{tuf_url}}/1.root.json" \
  --root-checksum="$ROOT_CHECKSUM"
```

This configures cosign to trust the TAS instance's Fulcio CA, Rekor public
key, and CT log key. Using `1.root.json` (version-specific) ensures a stable
checksum; `root.json` redirects to the latest version and may change between
rotations.

---

## Endpoint Validation

### Health Check Commands

```bash
# Validate Fulcio is reachable
curl -s -o /dev/null -w "%{http_code}" {{fulcio_url}}/healthz

# Validate Rekor is reachable
curl -s -o /dev/null -w "%{http_code}" {{rekor_url}}/api/v1/log

# Validate TSA is reachable (returns certificate chain)
curl -s -o /dev/null -w "%{http_code}" {{tsa_url}}/certchain

# Validate TUF root is downloadable
curl -s -o /dev/null -w "%{http_code}" {{tuf_url}}/root.json
```

### Expected HTTP Status Codes

| Endpoint | Success | Meaning |
|----------|---------|---------|
| Fulcio `/healthz` | 200 | Server is healthy |
| Rekor `/api/v1/log` | 200 | Log info returned |
| TSA `{{tsa_url}}/certchain` | 200 | Certificate chain returned |
| TUF `/root.json` | 200 | Root metadata available |

---

## CI/CD Environment Variable Mapping

Map TAS endpoint URLs to cosign CLI flags and environment variables:

| Endpoint | CLI Flag | Environment Variable |
|----------|----------|---------------------|
| Fulcio URL | `--fulcio-url` | `COSIGN_FULCIO_URL` |
| Rekor URL | `--rekor-url` | `COSIGN_REKOR_URL` |
| TSA URL | `--timestamp-server-url` | _(none — use flag)_ |
| OIDC Issuer | `--oidc-issuer` | _(none — use flag)_ |
| OIDC Client ID | `--oidc-client-id` | _(none — use flag)_ |

### Recommended CI/CD Variables

| Variable Name | Value | Description |
|---------------|-------|-------------|
| `TAS_REKOR_URL` | `{{rekor_url}}` | Rekor server base URL |
| `TAS_FULCIO_URL` | `{{fulcio_url}}` | Fulcio server base URL |
| `TAS_TSA_URL` | `{{tsa_url}}` | Timestamp Authority URL |
| `TAS_TUF_URL` | `{{tuf_url}}` | TUF mirror base URL |
| `TAS_OIDC_ISSUER` | `{{oidc_issuer}}` | OIDC token issuer URL |
| `TAS_OIDC_CLIENT_ID` | `{{oidc_client_id}}` | OIDC client ID |

---

## OpenShift Route Discovery

When TAS is deployed on OpenShift via the operator, component URLs are exposed
as routes. The scanner can discover them directly:

```bash
# List all TAS-related routes in the namespace
kubectl get routes -n {{namespace}} -l app.kubernetes.io/part-of=trusted-artifact-signer

# Get specific component routes
REKOR_URL=https://$(kubectl get route rekor-server -n {{namespace}} \
  -o jsonpath='{.spec.host}')

FULCIO_URL=https://$(kubectl get route fulcio-server -n {{namespace}} \
  -o jsonpath='{.spec.host}')

TSA_URL=https://$(kubectl get route tsa-server -n {{namespace}} \
  -o jsonpath='{.spec.host}')/api/v1/timestamp

TUF_URL=https://$(kubectl get route tuf -n {{namespace}} \
  -o jsonpath='{.spec.host}')
```

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
    Rekor              RekorSpec
    Fulcio             FulcioSpec
    Trillian           TrillianSpec
    Tuf                TufSpec
    Ctlog              CTlogSpec
    TimestampAuthority *TimestampAuthoritySpec
}
```

### SecuresignStatus (Observed State)

```go
type SecuresignStatus struct {
    Conditions []metav1.Condition
    RekorStatus  SecuresignRekorStatus
    FulcioStatus SecuresignFulcioStatus
    TufStatus    SecuresignTufStatus
    TSAStatus    SecuresignTSAStatus
}
```

### Component Status URL Fields

| Status Type | Field | Description |
|-------------|-------|-------------|
| `SecuresignRekorStatus` | `Url string` | Rekor server base URL |
| `SecuresignFulcioStatus` | `Url string` | Fulcio server base URL |
| `SecuresignTufStatus` | `Url string` | TUF mirror base URL |
| `SecuresignTSAStatus` | `Url string` | Timestamp Authority base URL |

### Discovering Endpoint URLs from the Operator

```bash
# Get all TAS component URLs from the Securesign CR status
kubectl get securesign -n {{namespace}} -o jsonpath='{.items[0].status}'

# Get individual component URLs
REKOR_URL=$(kubectl get securesign -n {{namespace}} \
  -o jsonpath='{.items[0].status.rekor.url}')

FULCIO_URL=$(kubectl get securesign -n {{namespace}} \
  -o jsonpath='{.items[0].status.fulcio.url}')

TUF_URL=$(kubectl get securesign -n {{namespace}} \
  -o jsonpath='{.items[0].status.tuf.url}')

TSA_URL=$(kubectl get securesign -n {{namespace}} \
  -o jsonpath='{.items[0].status.tsa.url}')
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

| Format | Example |
|--------|---------|
| OpenShift Route | `https://tsa-server-<namespace>.apps.<cluster-domain>` |
| Kubernetes Ingress | `https://tsa.<domain>` |
| Port-forward (dev) | `http://localhost:3002` |

Timestamp endpoint: `POST {{tsa_url}}/api/v1/timestamp`

Health check: `GET {{tsa_url}}/api/v1/timestamp/certchain`

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
initialized with the TAS TUF root:

```bash
cosign initialize --mirror={{tuf_url}} --root={{tuf_url}}/root.json
```

An optional `--root-checksum` flag verifies the root.json integrity:

```bash
cosign initialize --mirror={{tuf_url}} --root={{tuf_url}}/root.json \
  --root-checksum={{expected_sha256}}
```

This configures cosign to trust the TAS instance's Fulcio CA, Rekor public
key, and CT log key.

---

## Endpoint Validation

### Health Check Commands

```bash
# Validate Fulcio is reachable
curl -s -o /dev/null -w "%{http_code}" {{fulcio_url}}/healthz

# Validate Rekor is reachable
curl -s -o /dev/null -w "%{http_code}" {{rekor_url}}/api/v1/log

# Validate TSA is reachable (returns certificate chain)
curl -s -o /dev/null -w "%{http_code}" {{tsa_url}}/api/v1/timestamp/certchain

# Validate TUF root is downloadable
curl -s -o /dev/null -w "%{http_code}" {{tuf_url}}/root.json
```

### Expected HTTP Status Codes

| Endpoint | Success | Meaning |
|----------|---------|---------|
| Fulcio `/healthz` | 200 | Server is healthy |
| Rekor `/api/v1/log` | 200 | Log info returned |
| TSA `/api/v1/timestamp/certchain` | 200 | Certificate chain returned |
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
| `TAS_TSA_URL` | `{{tsa_url}}` | Timestamp Authority base URL |
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
  -o jsonpath='{.spec.host}')

TUF_URL=https://$(kubectl get route tuf -n {{namespace}} \
  -o jsonpath='{.spec.host}')
```

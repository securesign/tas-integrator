# OIDC Setup

Reference material for the TAS Integrator scanner. Documents OIDC issuer
configuration patterns for Fulcio, client ID setup, token injection methods
for CI/CD platforms, and Keycloak integration.

---

## OIDC Issuer Concepts

Fulcio uses OIDC identity tokens to issue short-lived code-signing certificates.
Each OIDC issuer must be registered in Fulcio's configuration with a URL, client
ID, and issuer type. The identity token's subject becomes the certificate's
Subject Alternative Name (SAN).

### Issuer Types

Fulcio supports the following issuer types (from `pkg/config/config.go`):

| Type | SAN Content | Use Case |
|------|-------------|----------|
| `email` | Email address from token | Human developer signing |
| `github-workflow` | GitHub Actions workflow identity | GitHub CI signing |
| `gitlab-pipeline` | GitLab CI pipeline identity | GitLab CI signing |
| `buildkite-job` | Buildkite job identity | Buildkite CI signing |
| `codefresh-workflow` | Codefresh workflow identity | Codefresh CI signing |
| `kubernetes` | ServiceAccount identity | In-cluster signing |
| `spiffe` | SPIFFE ID URI | SPIFFE workload identity |
| `uri` | URI from token subject | Generic URI-based identity |
| `username` | Username-derived email | Username-based identity |
| `chainguard-identity` | Chainguard identity | Chainguard workloads |
| `ci-provider` | CI provider identity | Generic CI provider |

---

## Fulcio OIDC Configuration Structure

### OIDCIssuer Fields (Fulcio Server)

From Fulcio `pkg/config/config.go`, each OIDC issuer entry includes:

| Field | Required | Description |
|-------|----------|-------------|
| `IssuerURL` | Yes | The OIDC discovery URL (e.g., `https://keycloak.example.com/realms/sigstore`) |
| `ClientID` | Yes | Expected `aud` claim value in the identity token |
| `Type` | Yes | Issuer type — determines SAN extraction (see table above) |
| `CIProvider` | No | Maps token claims to certificate extensions for CI workflows |
| `IssuerClaim` | No | Override claim name for issuer (default: `iss`) |
| `SubjectDomain` | No | Required domain in subject for `uri` types; email domain for `username` types |
| `SPIFFETrustDomain` | No | Required trust domain for `spiffe` types |
| `ChallengeClaim` | No | Custom challenge claim for non-standard issuers |
| `CACert` | No | PEM CA certificate to trust the OIDC provider's TLS certificate |
| `SkipEmailVerification` | No | Skip `email_verified` claim check (for providers like Microsoft Entra/ADFS) |

### Operator CRD OIDCIssuer Fields

From `api/v1alpha1/fulcio_types.go`, the operator's OIDCIssuer struct:

| Field | Required | Description |
|-------|----------|-------------|
| `Issuer` | Yes | The OIDC issuer identifier |
| `IssuerURL` | No | The OIDC token issuer URL |
| `ClientID` | Yes | Expected audience in the identity token |
| `Type` | Yes | Issuer type string |
| `CIProvider` | No | CI provider mapping |
| `IssuerClaim` | No | Override issuer claim |
| `SubjectDomain` | No | Domain for subject matching |
| `SPIFFETrustDomain` | No | SPIFFE trust domain |
| `ChallengeClaim` | No | Custom challenge claim |

### FulcioConfig Structure (Operator CRD)

```go
type FulcioConfig struct {
    OIDCIssuers      []OIDCIssuer      // Named issuers with exact URL match
    MetaIssuers      []OIDCIssuer      // Wildcard issuers (e.g., *.amazonaws.com)
    CIIssuerMetadata []CIIssuerMetadata // CI extension template metadata
}
```

---

## Keycloak OIDC Integration

### Keycloak Realm Configuration for TAS

| Setting | Value | Notes |
|---------|-------|-------|
| Realm URL | `https://{{keycloak_host}}/realms/{{realm_name}}` | OIDC discovery at `/.well-known/openid-configuration` |
| Client ID | `sigstore` (typical) | Must match Fulcio `ClientID` |
| Client Protocol | `openid-connect` | Standard OIDC |
| Access Type | `public` | No client secret needed for token exchange |
| Valid Redirect URIs | `http://localhost/*` | For interactive cosign login |
| Web Origins | `+` | Allow CORS from redirect URIs |

### Keycloak Issuer URL Patterns

| Keycloak Version | Issuer URL Pattern |
|------------------|--------------------|
| Keycloak 17+ (Quarkus) | `https://{{keycloak_host}}/realms/{{realm_name}}` |
| Keycloak < 17 (WildFly) | `https://{{keycloak_host}}/auth/realms/{{realm_name}}` |
| Red Hat SSO 7.x | `https://{{sso_host}}/auth/realms/{{realm_name}}` |
| RHBK (Red Hat Build of Keycloak) | `https://{{rhbk_host}}/realms/{{realm_name}}` |

### Keycloak Token Endpoint

To obtain an identity token for CI/CD (service account or direct grant):

```bash
# Service account token (client credentials grant)
IDENTITY_TOKEN=$(curl -s -X POST \
  "https://{{keycloak_host}}/realms/{{realm_name}}/protocol/openid-connect/token" \
  -d "grant_type=client_credentials" \
  -d "client_id={{client_id}}" \
  -d "client_secret={{client_secret}}" \
  | jq -r '.access_token')

# User token (resource owner password grant — dev/test only)
IDENTITY_TOKEN=$(curl -s -X POST \
  "https://{{keycloak_host}}/realms/{{realm_name}}/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id={{client_id}}" \
  -d "username={{username}}" \
  -d "password={{password}}" \
  -d "scope=openid email" \
  | jq -r '.access_token')
```

---

## CI/CD Token Injection Patterns

### GitHub Actions

GitHub provides OIDC tokens natively via the `actions/github-script` action or
the `ACTIONS_ID_TOKEN_REQUEST_URL` environment variable.

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - name: Get OIDC token
    id: oidc
    uses: actions/github-script@v7
    with:
      script: |
        const token = await core.getIDToken('sigstore')
        core.setOutput('token', token)
```

Cosign detects GitHub Actions automatically via ambient credential providers
when `--oidc-disable-ambient-providers` is not set.

| Environment Variable | Purpose |
|---------------------|---------|
| `ACTIONS_ID_TOKEN_REQUEST_URL` | OIDC token request endpoint |
| `ACTIONS_ID_TOKEN_REQUEST_TOKEN` | Bearer token for OIDC endpoint |

### GitLab CI

GitLab provides OIDC tokens via the `CI_JOB_JWT_V2` or `SIGSTORE_ID_TOKEN`
variable, or through the `id_tokens` keyword.

```yaml
signing-job:
  id_tokens:
    SIGSTORE_ID_TOKEN:
      aud: sigstore
  script:
    - cosign sign --identity-token=$SIGSTORE_ID_TOKEN ...
```

| Environment Variable | Purpose |
|---------------------|---------|
| `SIGSTORE_ID_TOKEN` | Preferred — Sigstore-specific token variable |
| `CI_JOB_JWT_V2` | GitLab-managed OIDC token |
| `CI_JOB_JWT` | Legacy GitLab OIDC token (deprecated) |

### Jenkins

Jenkins does not provide native OIDC tokens. Token must be obtained from an
external identity provider (e.g., Keycloak).

```groovy
environment {
    IDENTITY_TOKEN = sh(
        script: '''
            curl -s -X POST \
              "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
              -d "grant_type=client_credentials" \
              -d "client_id=${OIDC_CLIENT_ID}" \
              -d "client_secret=${OIDC_CLIENT_SECRET}" \
              | jq -r '.access_token'
        ''',
        returnStdout: true
    ).trim()
}
```

### Tekton Pipelines

Tekton on OpenShift can use SPIFFE-based workload identity or fetch tokens
from the cluster's OIDC provider.

```yaml
steps:
  - name: get-token
    image: curlimages/curl
    script: |
      TOKEN=$(cat /var/run/sigstore/cosign/oidc-token)
      echo -n "$TOKEN" > $(results.identity-token.path)
```

---

## Fulcio OIDC Config File Format

The Fulcio server reads OIDC configuration from a YAML config file. The Ansible
collection uses a Jinja2 template (`fulcio-oidc.conf.j2`) to generate it.

### YAML Structure

```yaml
oidc-issuers:
  "https://keycloak.example.com/realms/sigstore":
    issuer-url: "https://keycloak.example.com/realms/sigstore"
    client-id: "sigstore"
    type: "email"
  "https://accounts.google.com":
    issuer-url: "https://accounts.google.com"
    client-id: "sigstore"
    type: "email"
meta-issuers:
  "https://oidc.eks.*.amazonaws.com/id/*":
    client-id: "sigstore"
    type: "kubernetes"
ci-issuer-metadata:
  "github-actions":
    subject-alternative-name-template: "..."
    extension-templates:
      build-signer-uri: "..."
```

### Ansible Variable Structure

The Ansible collection configures OIDC issuers through the
`tas_single_node_fulcio` variable:

```yaml
tas_single_node_fulcio:
  fulcio_config:
    oidc_issuers:
      - issuer: "https://keycloak.example.com/realms/sigstore"
        url: "https://keycloak.example.com/realms/sigstore"
        client_id: "sigstore"
        type: "email"
    meta_issuers:
      - issuer_pattern: "https://oidc.eks.*.amazonaws.com/id/*"
        client_id: "sigstore"
        type: "kubernetes"
    ci_issuer_metadata: []
```

---

## Meta Issuers (Wildcard OIDC)

Meta issuers use wildcard patterns to match OIDC providers with dynamic URLs,
such as cloud-managed Kubernetes OIDC endpoints.

| Pattern | Cloud Provider | Use Case |
|---------|---------------|----------|
| `https://oidc.eks.*.amazonaws.com/id/*` | AWS EKS | EKS cluster OIDC |
| `https://container.googleapis.com/v1/projects/*/locations/*/clusters/*` | GKE | GKE cluster OIDC |
| `https://token.actions.githubusercontent.com` | GitHub | GitHub Actions OIDC |

Wildcard `*` matches a single path segment (no `/` or `.`).

---

## Cosign OIDC Flags

When invoking cosign against a TAS instance, the following OIDC-related flags
configure identity token acquisition:

| Flag | Description |
|------|-------------|
| `--oidc-issuer` | OIDC issuer URL (must match Fulcio config) |
| `--oidc-client-id` | OIDC client ID (must match Fulcio config) |
| `--oidc-client-secret-file` | Path to file containing OIDC client secret |
| `--oidc-redirect-url` | Redirect URL for browser-based OIDC flow |
| `--oidc-provider` | Named ambient credential provider |
| `--oidc-disable-ambient-providers` | Disable automatic OIDC token detection |
| `--identity-token` | Pre-fetched OIDC identity token |

### Typical CI/CD Invocation

```bash
cosign sign \
  --fulcio-url={{fulcio_url}} \
  --rekor-url={{rekor_url}} \
  --oidc-issuer={{oidc_issuer}} \
  --oidc-client-id={{oidc_client_id}} \
  --identity-token={{identity_token}} \
  --yes \
  {{image_reference}}
```

---

## Scanner Detection Rules

When scanning a CI/CD environment for OIDC configuration, look for:

| Pattern | Indicates |
|---------|-----------|
| `--oidc-issuer` in scripts | Custom OIDC issuer configured |
| `--oidc-client-id` in scripts | Custom OIDC client configured |
| `--identity-token` in scripts | Pre-fetched token flow |
| `SIGSTORE_ID_TOKEN` env var | GitLab OIDC token injection |
| `ACTIONS_ID_TOKEN_REQUEST_URL` env var | GitHub Actions OIDC |
| `id_tokens:` in `.gitlab-ci.yml` | GitLab native OIDC |
| `permissions: id-token: write` in workflow | GitHub Actions OIDC permission |
| Keycloak URL in env vars | Keycloak-based OIDC |
| `--oidc-disable-ambient-providers` | Explicit token management |

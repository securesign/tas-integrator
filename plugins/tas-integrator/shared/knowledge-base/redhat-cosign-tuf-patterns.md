# Red Hat Cosign TUF and Service URL Patterns

Critical reference for Red Hat securesign/cosign 3.x behavior with TUF
initialization and explicit service URLs. Documents when service URLs can and
cannot be specified to avoid "cannot specify service URLs and use signing config"
errors.

---

## The TUF vs Explicit URLs Rule

Red Hat cosign 3.x enforces strict separation between two modes:

| Mode | Description | When to Use |
|------|-------------|-------------|
| **TUF Mode** | Uses TUF metadata for service URLs | Private TAS deployments (recommended) |
| **Explicit URL Mode** | All service URLs via CLI flags | No TUF available / public Sigstore |

**Critical Rule:** You CANNOT mix TUF configuration with explicit service URL flags.

## Error: "cannot specify service URLs and use signing config"

This error occurs when cosign detects both:
1. A TUF/signing config (from `cosign initialize` or embedded defaults)
2. Explicit service URL flags (`--fulcio-url`, `--rekor-url`, `--oidc-issuer`)

### When This Error Occurs

```bash
# This FAILS after TUF initialization:
cosign initialize --mirror=$TUF_URL --root=$TUF_URL/1.root.json ...
cosign sign \
  --fulcio-url=$FULCIO_URL \    # ❌ Error: cannot specify with TUF config
  --rekor-url=$REKOR_URL \      # ❌ Error: cannot specify with TUF config
  --oidc-issuer=$OIDC_ISSUER \  # ❌ Error: cannot specify with TUF config
  --identity-token=$TOKEN \
  $IMAGE
```

**Why:** After `cosign initialize`, TUF metadata provides Fulcio/Rekor URLs.
Specifying them again creates a conflict.

---

## Pattern 1: TUF Mode (Red Hat TAS Recommended)

**When to use:** Private TAS deployments on OpenShift with self-signed certificates.

### Step 1: Clear any existing TUF config

```bash
rm -rf ~/.sigstore
```

### Step 2: Trust TAS server certificates

```bash
# Extract CA certificate
TAS_HOST=$(echo "$TAS_TUF_URL" | sed 's|^https://||' | cut -d/ -f1)
echo | openssl s_client -showcerts -connect "${TAS_HOST}:443" 2>/dev/null \
  | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > /tmp/tuf-ca.crt

# Set for curl and cosign
export SSL_CERT_FILE=/tmp/tuf-ca.crt
export CURL_CA_BUNDLE=/tmp/tuf-ca.crt
```

### Step 3: Initialize TUF

```bash
ROOT_CHECKSUM=$(curl -s "${TAS_TUF_URL}/1.root.json" | sha256sum | awk '{print $1}')
cosign initialize \
  --mirror="${TAS_TUF_URL}" \
  --root="${TAS_TUF_URL}/1.root.json" \
  --root-checksum="${ROOT_CHECKSUM}"
```

### Step 4: Sign using environment variables (NO explicit URLs)

```bash
export COSIGN_YES=true
export COSIGN_OIDC_CLIENT_ID=trusted-artifact-signer
export SIGSTORE_ID_TOKEN=${IDENTITY_TOKEN}  # Pre-acquired OIDC token

# Sign - TUF provides Fulcio/Rekor URLs automatically
cosign sign ${IMAGE}
```

**What you CAN specify after TUF init:**
- ✅ `COSIGN_OIDC_CLIENT_ID` (env var)
- ✅ `SIGSTORE_ID_TOKEN` (env var for token)
- ✅ `COSIGN_YES` (env var to skip prompts)
- ✅ `--certificate-identity` and `--certificate-oidc-issuer` (for verify only)

**What you CANNOT specify after TUF init:**
- ❌ `--fulcio-url` (TUF provides this)
- ❌ `--rekor-url` (TUF provides this)
- ❌ `--oidc-issuer` (conflicts with TUF, use env var instead)
- ❌ `--identity-token` (use `SIGSTORE_ID_TOKEN` env var instead)

### Step 5: Verify using environment variables

```bash
export SSL_CERT_FILE=/tmp/tuf-ca.crt
export CURL_CA_BUNDLE=/tmp/tuf-ca.crt

cosign verify \
  --certificate-identity=service-account@trusted-artifact-signer.local \
  --certificate-oidc-issuer=${TAS_OIDC_ISSUER} \
  ${IMAGE}
```

**Note:** Certificate verification flags are allowed because they verify the
*signature contents*, not the *service endpoints*.

---

## Pattern 2: Explicit URL Mode (No TUF)

**When to use:** 
- Public Sigstore (no private TUF)
- Legacy environments
- Testing without TUF setup

### Requirements

- No TUF initialization
- No `~/.sigstore/` directory
- Unset `SIGSTORE_ROOT_FILE`, `COSIGN_REKOR_URL`, `COSIGN_FULCIO_URL`

### Sign with explicit URLs

```bash
# Ensure no TUF config exists
rm -rf ~/.sigstore
unset SIGSTORE_ROOT_FILE
unset COSIGN_REKOR_URL

cosign sign \
  --fulcio-url=${TAS_FULCIO_URL} \
  --rekor-url=${TAS_REKOR_URL} \
  --oidc-issuer=${TAS_OIDC_ISSUER} \
  --oidc-client-id=${TAS_OIDC_CLIENT_ID} \
  --identity-token=${IDENTITY_TOKEN} \
  --yes \
  ${IMAGE}
```

### Verify with explicit URLs

```bash
cosign verify \
  --rekor-url=${TAS_REKOR_URL} \
  --certificate-identity=service-account@trusted-artifact-signer.local \
  --certificate-oidc-issuer=${TAS_OIDC_ISSUER} \
  ${IMAGE}
```

---

## Detection Logic for Scanners

When scanning a CI/CD pipeline, determine which mode is in use:

### Indicators of TUF Mode

**Pipeline contains:**
- `cosign initialize --mirror=...` command
- Environment variables but NO explicit URL flags
- `SIGSTORE_ID_TOKEN` env var (not `--identity-token` flag)
- `COSIGN_OIDC_CLIENT_ID` env var (not `--oidc-client-id` flag)

**Example (Jenkins Groovy):**
```groovy
sh '''
    cosign initialize --mirror="${TAS_TUF_URL}" ...
'''
sh """
    export COSIGN_YES=true
    export COSIGN_OIDC_CLIENT_ID=${TAS_OIDC_CLIENT_ID}
    export SIGSTORE_ID_TOKEN=${IDENTITY_TOKEN}
    
    cosign sign ${IMAGE}  # No --fulcio-url, --rekor-url
"""
```

### Indicators of Explicit URL Mode

**Pipeline contains:**
- NO `cosign initialize` command
- `--fulcio-url` and `--rekor-url` flags in sign/attest
- `--identity-token` flag (not env var)
- `--oidc-issuer` flag

**Example (Jenkins):**
```groovy
sh '''
    cosign sign \
        --fulcio-url=${TAS_FULCIO_URL} \
        --rekor-url=${TAS_REKOR_URL} \
        --oidc-issuer=${TAS_OIDC_ISSUER} \
        --identity-token=${TOKEN} \
        ${IMAGE}
'''
```

---

## Common Pitfalls

### Pitfall 1: Embedded Sigstore Config

Some cosign binaries have embedded public Sigstore TUF roots. These can trigger
the "cannot specify service URLs" error even without explicit `cosign initialize`.

**Solution:** Use `COSIGN_EXPERIMENTAL=0` or clear `~/.sigstore/`

### Pitfall 2: Environment Variables vs Flags

After TUF init, using flags instead of env vars fails:

```bash
# ❌ WRONG (after TUF init)
cosign sign --identity-token=$TOKEN $IMAGE

# ✅ CORRECT (after TUF init)
export SIGSTORE_ID_TOKEN=$TOKEN
cosign sign $IMAGE
```

### Pitfall 3: Mixed Patterns in Same Pipeline

```bash
# ❌ WRONG: Initialize TUF then use explicit URLs
cosign initialize --mirror=$TUF_URL ...
cosign sign --fulcio-url=$FULCIO_URL ...  # Error!

# ✅ CORRECT: Pick one pattern
cosign initialize --mirror=$TUF_URL ...
export SIGSTORE_ID_TOKEN=$TOKEN
cosign sign $IMAGE
```

---

## Blueprint Generation Guidance

When generating blueprints for users:

### For Private TAS (with self-signed certs)

**Recommend:** TUF Mode
- Include TUF initialization step
- Use environment variables for auth
- Extract and trust CA certificate first
- No explicit `--fulcio-url`, `--rekor-url` in sign/verify

### For Public TAS (with valid certs)

**Recommend:** Explicit URL Mode (simpler)
- Skip TUF initialization
- Use flags for all service URLs
- Simpler for users to understand

### Detected Hybrid (TUF + Explicit URLs)

**Action:** Warn user about incompatibility
- Explain the conflict
- Recommend migrating to pure TUF mode
- Provide migration steps

---

## Version Compatibility

| Cosign Version | TUF Support | Strict Separation |
|----------------|-------------|-------------------|
| securesign/cosign 3.x | ✅ Yes | ✅ Enforced (errors on mix) |
| sigstore/cosign 2.x | ✅ Yes | ⚠️ Warnings only |
| sigstore/cosign 1.x | ⚠️ Partial | ❌ Not enforced |

**Red Hat securesign/cosign 3.x is STRICT** - it will error, not warn.

---

## Related Environment Variables

| Variable | TUF Mode | Explicit URL Mode |
|----------|----------|-------------------|
| `SIGSTORE_ID_TOKEN` | ✅ Use this | ❌ Use `--identity-token` flag instead |
| `COSIGN_OIDC_CLIENT_ID` | ✅ Use this | ❌ Use `--oidc-client-id` flag instead |
| `COSIGN_YES` | ✅ Recommended | ✅ Recommended |
| `SSL_CERT_FILE` | ✅ Required for self-signed | ✅ Required for self-signed |
| `CURL_CA_BUNDLE` | ✅ Required for self-signed | ✅ Required for self-signed |
| `COSIGN_REKOR_URL` | ❌ Conflicts with TUF | ✅ Alternative to flag |
| `COSIGN_FULCIO_URL` | ❌ Conflicts with TUF | ✅ Alternative to flag |
| `SIGSTORE_ROOT_FILE` | ❌ Conflicts with TUF | ⚠️ Advanced use only |

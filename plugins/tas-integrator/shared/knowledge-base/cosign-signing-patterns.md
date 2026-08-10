# Cosign Signing Patterns

Reference material for the TAS Integrator scanner. Documents cosign CLI flags,
environment variables, and command patterns for container image signing,
attestation, and verification workflows.

---

## Sign Command

Signs a container image using `cosign sign`.

### Key Flags

| Flag | Type | Description |
|------|------|-------------|
| `--key` | string | Path to private key or KMS URI |
| `--certificate` | string | Path to PEM-encoded x509 certificate |
| `--certificate-chain` | string | Path to PEM-encoded x509 certificate chain |
| `--fulcio-url` | string | Fulcio server URL (keyless signing) |
| `--fulcio-auth-flow` | string | OAuth2 flow type (normal\|device\|token\|client_credentials) |
| `--insecure-skip-verify` | bool | Skip verifying Fulcio SCT |
| `--rekor-url` | string | Rekor transparency log URL |
| `--oidc-issuer` | string | OIDC token issuer URL |
| `--oidc-client-id` | string | OIDC client ID for authentication |
| `--oidc-client-secret-file` | string | Path to file containing OIDC client secret |
| `--oidc-redirect-url` | string | OIDC redirect URL |
| `--oidc-provider` | string | OIDC provider to use for ambient credentials |
| `--oidc-disable-ambient-providers` | bool | Disable ambient OIDC credential detection |
| `--identity-token` | string | Pre-fetched OIDC identity token |
| `--tlog-upload` | bool | Upload signature to transparency log (default true; **deprecated** — prefer --signing-config) |
| `--upload` | bool | Upload signature to registry (default true) |
| `--output-signature` | string | Write signature to file |
| `--output-payload` | string | Write payload to file |
| `--output-certificate` | string | Write certificate to file |
| `--bundle` | string | Write Sigstore bundle to file |
| `--recursive` | bool | Sign all images in a multi-arch manifest |
| `--yes` | bool | Skip confirmation prompts |
| `--timestamp-server-url` | string | RFC 3161 timestamp authority URL |
| `--timestamp-client-cacert` | string | TSA TLS CA certificate path |
| `--timestamp-client-cert` | string | TSA TLS client certificate path |
| `--timestamp-client-key` | string | TSA TLS client key path |
| `--timestamp-server-name` | string | TSA TLS server name override |
| `--issue-certificate` | bool | Issue a code signing certificate from Fulcio |
| `--signing-config` | string | Path to signing config file |
| `--use-signing-config` | bool | Use TUF-provided signing config for service URLs (default true) |
| `--trusted-root` | string | Path to trusted root file |
| `--new-bundle-format` | bool | Use new Sigstore bundle format (default true) |
| `--record-creation-timestamp` | bool | Record creation timestamp in bundle |
| `--payload` | string | Path to a payload file to sign |
| `--sign-container-identity` | []string | Override container identity for signing |

### Keyless Signing Pattern (TAS Default)

```bash
cosign sign \
  --fulcio-url={{fulcio_url}} \
  --rekor-url={{rekor_url}} \
  --oidc-issuer={{oidc_issuer}} \
  --oidc-client-id={{oidc_client_id}} \
  --identity-token={{identity_token}} \
  --tlog-upload=true \
  --yes \
  {{image_reference}}
```

### Key-Based Signing Pattern

```bash
cosign sign \
  --key={{key_path_or_kms_uri}} \
  --rekor-url={{rekor_url}} \
  --tlog-upload=true \
  --yes \
  {{image_reference}}
```

### TAS Signing with TSA

```bash
cosign sign \
  --fulcio-url={{fulcio_url}} \
  --rekor-url={{rekor_url}} \
  --timestamp-server-url={{tsa_url}} \
  --oidc-issuer={{oidc_issuer}} \
  --oidc-client-id={{oidc_client_id}} \
  --identity-token={{identity_token}} \
  --yes \
  {{image_reference}}
```

---

## Attest Command

Attaches an attestation to a container image using `cosign attest`.

### Key Flags

| Flag | Type | Description |
|------|------|-------------|
| `--key` | string | Path to private key or KMS URI |
| `--certificate` | string | Path to PEM-encoded x509 certificate |
| `--certificate-chain` | string | Path to PEM-encoded x509 certificate chain |
| `--fulcio-url` | string | Fulcio server URL |
| `--rekor-url` | string | Rekor transparency log URL |
| `--predicate` | string | Path to predicate file |
| `--statement` | string | Path to in-toto statement (alternative to --predicate) |
| `--type` | string | Predicate type (e.g., slsaprovenance, spdxjson, cyclonedx) |
| `--no-upload` | bool | Do not upload attestation to registry |
| `--replace` | bool | Replace existing attestation |
| `--rekor-entry-type` | string | Type of entry to create in Rekor |
| `--tlog-upload` | bool | Upload attestation to transparency log (**deprecated** — prefer --signing-config) |
| `--timestamp-server-url` | string | RFC 3161 timestamp authority URL |
| `--signing-config` | string | Path to signing config file |
| `--use-signing-config` | bool | Use TUF-provided signing config for service URLs (default true) |
| `--trusted-root` | string | Path to trusted root file |
| `--new-bundle-format` | bool | Use new Sigstore bundle format (default true) |
| `--bundle` | string | Write Sigstore bundle to file |
| `--record-creation-timestamp` | bool | Record creation timestamp in bundle |

### Keyless Attestation Pattern

```bash
cosign attest \
  --fulcio-url={{fulcio_url}} \
  --rekor-url={{rekor_url}} \
  --oidc-issuer={{oidc_issuer}} \
  --oidc-client-id={{oidc_client_id}} \
  --identity-token={{identity_token}} \
  --predicate={{predicate_file}} \
  --type={{predicate_type}} \
  --yes \
  {{image_reference}}
```

---

## Verify Command

Verifies a signed container image using `cosign verify`.

### Key Flags

| Flag | Type | Description |
|------|------|-------------|
| `--key` | string | Path to public key or KMS URI |
| `--certificate` | string | Path to expected signing certificate |
| `--certificate-identity` | string | Expected identity in the signing certificate |
| `--certificate-identity-regexp` | string | Regex for expected certificate identity |
| `--certificate-oidc-issuer` | string | Expected OIDC issuer in the certificate |
| `--certificate-oidc-issuer-regexp` | string | Regex for expected OIDC issuer |
| `--certificate-github-workflow-trigger` | string | Expected GitHub workflow trigger |
| `--certificate-github-workflow-sha` | string | Expected GitHub workflow SHA |
| `--certificate-github-workflow-name` | string | Expected GitHub workflow name |
| `--certificate-github-workflow-repository` | string | Expected GitHub workflow repository |
| `--certificate-github-workflow-ref` | string | Expected GitHub workflow ref |
| `--ca-intermediates` | string | Path to CA intermediate certificates |
| `--ca-roots` | string | Path to CA root certificates |
| `--certificate-chain` | string | Path to PEM-encoded certificate chain for verification |
| `--sct` | string | Path to signed certificate timestamp |
| `--insecure-ignore-sct` | bool | Skip SCT verification |
| `--rekor-url` | string | Rekor transparency log URL |
| `--check-claims` | bool | Check claims in the signature (default true) |
| `--output` | string | Output format (json or text) |
| `--local-image` | bool | Verify a local image instead of remote |
| `--offline` | bool | Force offline verification (**deprecated** — use --bundle with --trusted-root) |
| `--insecure-ignore-tlog` | bool | Skip transparency log verification |
| `--timestamp-certificate-chain` | string | Path to TSA certificate chain for timestamp verification |
| `--max-workers` | int | Maximum concurrent verification workers |
| `--private-infrastructure` | bool | Skip tlog/SCT verification for private deployments |
| `--use-signed-timestamps` | bool | Use signed timestamps for verification |
| `--new-bundle-format` | bool | Expect new Sigstore bundle format (default true) |
| `--trusted-root` | string | Path to trusted root file |
| `--experimental-oci11` | bool | Enable experimental OCI 1.1 behaviour |

### Keyless Verification Pattern (TAS)

```bash
cosign verify \
  --rekor-url={{rekor_url}} \
  --certificate-identity={{expected_identity}} \
  --certificate-oidc-issuer={{oidc_issuer}} \
  {{image_reference}}
```

### Key-Based Verification Pattern

```bash
cosign verify \
  --key={{public_key_path}} \
  --rekor-url={{rekor_url}} \
  {{image_reference}}
```

### Private Infrastructure Verification

```bash
cosign verify \
  --certificate-identity={{expected_identity}} \
  --certificate-oidc-issuer={{oidc_issuer}} \
  --ca-roots={{ca_roots_path}} \
  --private-infrastructure \
  {{image_reference}}
```

---

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `COSIGN_REKOR_URL` | Default Rekor server URL (overridden by `--rekor-url`) |
| `COSIGN_FULCIO_URL` | Default Fulcio server URL (overridden by `--fulcio-url`) |
| `COSIGN_CERTIFICATE` | Default signing certificate path |
| `COSIGN_PASSWORD` | Password for encrypted private keys |
| `COSIGN_EXPERIMENTAL` | Enable experimental features (legacy; use flags instead) |
| `COSIGN_OUTPUT_FILE` | Default output file path |
| `COSIGN_PKCS11_MODULE_PATH` | PKCS#11 module path for hardware tokens |
| `COSIGN_DOCKER_MEDIA_TYPES` | Use Docker media types instead of OCI |
| `COSIGN_MAX_ATTACHMENT_SIZE` | Maximum attachment size in bytes |
| `COSIGN_REPOSITORY` | Override the OCI registry for signature/attestation storage |
| `SIGSTORE_REKOR_PUBLIC_KEY` | Path to Rekor public key for offline verification |
| `SIGSTORE_ROOT_FILE` | Path to Sigstore root of trust file |
| `SIGSTORE_TSA_CERTIFICATE_FILE` | Path to TSA certificate file for timestamp verification |
| `SIGSTORE_ID_TOKEN` | Pre-fetched OIDC identity token (used by CI/CD ambient providers) |
| `TUF_ROOT` | TUF root directory path |
| `TUF_MIRROR` | TUF mirror URL |
| `TUF_ROOT_JSON` | Path to initial TUF root.json file |
| `SOURCE_DATE_EPOCH` | Unix timestamp for reproducible builds; sets creation timestamp |

### Flag Aliases (Backward Compatibility)

Cosign normalizes abbreviated `cert` flag names to their canonical `certificate`
form. Both forms are accepted:

| Alias (short) | Canonical (preferred) |
|----------------|-----------------------|
| `--cert` | `--certificate` |
| `--cert-chain` | `--certificate-chain` |
| `--cert-identity` | `--certificate-identity` |
| `--cert-oidc-issuer` | `--certificate-oidc-issuer` |
| `--cert-email` | `--certificate-email` |
| `--output-cert` | `--output-certificate` |

Generated snippets should use the canonical form. When scanning existing
pipelines, match both forms.

---

## CI/CD Integration Patterns

### Environment Variable Detection

When scanning a CI/CD environment, look for these variables to detect existing
cosign configuration:

| Variable Pattern | Indicates |
|-----------------|-----------|
| `COSIGN_REKOR_URL` | Custom Rekor server configured |
| `COSIGN_CERTIFICATE` | Certificate-based signing in use |
| `COSIGN_PASSWORD` | Key-based signing with encrypted key |
| `SIGSTORE_ROOT_FILE` | Custom Sigstore root of trust |
| `COSIGN_EXPERIMENTAL` | Legacy keyless mode enabled |

### OIDC Provider Ambient Credentials

Cosign supports automatic OIDC token acquisition from CI/CD platforms:

| Provider | Environment | Token Source |
|----------|-------------|--------------|
| GitHub Actions | `ACTIONS_ID_TOKEN_REQUEST_URL` | GitHub OIDC provider |
| GitLab CI | `SIGSTORE_ID_TOKEN` or `CI_JOB_JWT` | GitLab OIDC provider |
| Google Cloud | GCE metadata service | Workload identity |
| Buildkite | `BUILDKITE_AGENT_OIDC_TOKEN` | Buildkite OIDC provider |

Ambient providers can be disabled with `--oidc-disable-ambient-providers`.

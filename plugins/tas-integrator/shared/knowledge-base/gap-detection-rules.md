# Gap Detection Rules

Reference material for the TAS Integrator scanner. Defines the checklist of TAS
integration requirements that scanners evaluate against when analyzing a CI/CD
environment. Each rule has a category, detection method, and remediation
guidance.

---

## Rule Categories

| Category | Code | Description |
|----------|------|-------------|
| Infrastructure | `INFRA` | TAS deployment and endpoint availability |
| OIDC | `OIDC` | Identity provider configuration |
| Signing | `SIGN` | Container image signing setup |
| Verification | `VERIFY` | Signature verification setup |
| Policy | `POLICY` | Admission control and governance |
| Supply Chain | `SUPPLY` | SBOM, attestation, and provenance |

---

## Infrastructure Rules

### INFRA-001: TAS Deployment Exists

| Field | Value |
|-------|-------|
| Severity | Critical |
| Description | A Trusted Artifact Signer instance must be deployed and accessible |
| Detection | Check for Securesign CRD on OpenShift, `/etc/rhtas/` on RHEL, or TAS endpoint environment variables |
| Pass Condition | At least one TAS deployment method detected |
| Remediation | Deploy TAS via OpenShift operator or Ansible collection |

### INFRA-002: Fulcio Endpoint Reachable

| Field | Value |
|-------|-------|
| Severity | Critical |
| Description | The Fulcio server must be reachable for certificate issuance |
| Detection | `GET {{fulcio_url}}/healthz` returns HTTP 200 |
| Pass Condition | Health check returns 200 |
| Remediation | Verify Fulcio pod is running, check route/ingress configuration, verify network policies |

### INFRA-003: Rekor Endpoint Reachable

| Field | Value |
|-------|-------|
| Severity | Critical |
| Description | The Rekor transparency log must be reachable for log entries |
| Detection | `GET {{rekor_url}}/api/v1/log` returns HTTP 200 |
| Pass Condition | Health check returns 200 |
| Remediation | Verify Rekor pod is running, check route/ingress configuration |

### INFRA-004: TUF Root Available

| Field | Value |
|-------|-------|
| Severity | High |
| Description | TUF root metadata must be available for cosign initialization |
| Detection | `GET {{tuf_url}}/root.json` returns HTTP 200 |
| Pass Condition | Root metadata downloadable |
| Remediation | Verify TUF pod is running, ensure TUF root has been initialized |

### INFRA-005: TSA Endpoint Reachable

| Field | Value |
|-------|-------|
| Severity | Medium |
| Description | The Timestamp Authority should be reachable for RFC 3161 timestamps |
| Detection | `GET {{tsa_url}}/api/v1/timestamp/certchain` returns HTTP 200 |
| Pass Condition | Certificate chain returned |
| Remediation | Verify TSA pod is running; TSA is optional but recommended |

### INFRA-006: Cosign CLI Available

| Field | Value |
|-------|-------|
| Severity | Critical |
| Description | The cosign CLI must be installed in the CI/CD environment |
| Detection | `cosign version` exits with code 0 |
| Pass Condition | cosign binary found and executable |
| Remediation | Install cosign via package manager, container image, or binary download |

---

## OIDC Rules

### OIDC-001: OIDC Issuer Configured

| Field | Value |
|-------|-------|
| Severity | Critical |
| Description | An OIDC issuer must be configured in Fulcio for identity-based signing |
| Detection | Check `--oidc-issuer` flag usage, `OIDC_ISSUER` env var, or Fulcio config YAML |
| Pass Condition | OIDC issuer URL present and matches a Fulcio-registered issuer |
| Remediation | Configure OIDC issuer in Fulcio config and pass via `--oidc-issuer` flag |

### OIDC-002: OIDC Client ID Configured

| Field | Value |
|-------|-------|
| Severity | Critical |
| Description | An OIDC client ID must match the Fulcio-registered client |
| Detection | Check `--oidc-client-id` flag usage or environment variables |
| Pass Condition | Client ID present and matches Fulcio configuration |
| Remediation | Set `--oidc-client-id` to the value registered in Fulcio (typically `trusted-artifact-signer` for TAS) |

### OIDC-003: Identity Token Available

| Field | Value |
|-------|-------|
| Severity | Critical |
| Description | An OIDC identity token must be obtainable in the CI/CD environment |
| Detection | Check for ambient providers (GitHub `ACTIONS_ID_TOKEN_REQUEST_URL`, GitLab `SIGSTORE_ID_TOKEN`), `--identity-token` flag, or Keycloak token endpoint |
| Pass Condition | At least one token acquisition method available |
| Remediation | Enable OIDC token generation for the CI platform, or configure Keycloak service account credentials |

### OIDC-004: OIDC Discovery Endpoint Accessible

| Field | Value |
|-------|-------|
| Severity | High |
| Description | The OIDC provider's discovery endpoint must be reachable from the CI runner |
| Detection | `GET {{oidc_issuer}}/.well-known/openid-configuration` returns HTTP 200 |
| Pass Condition | Discovery document returned with valid JSON |
| Remediation | Check network connectivity, DNS resolution, and TLS trust for the OIDC provider |

---

## Signing Rules

### SIGN-001: Signing Step Present

| Field | Value |
|-------|-------|
| Severity | Critical |
| Description | The CI/CD pipeline must include a container image signing step |
| Detection | Search for `cosign sign` command in pipeline configuration |
| Pass Condition | At least one signing command found |
| Remediation | Add a signing step to the pipeline using `cosign sign` |

### SIGN-002: Fulcio URL Configured for Signing

| Field | Value |
|-------|-------|
| Severity | Critical |
| Description | The `--fulcio-url` flag must point to the TAS Fulcio instance for keyless signing |
| Detection | Check `cosign sign` invocations for `--fulcio-url` flag |
| Pass Condition | `--fulcio-url` present and points to TAS Fulcio endpoint |
| Remediation | Add `--fulcio-url={{fulcio_url}}` to the cosign sign command |

### SIGN-003: Rekor URL Configured for Signing

| Field | Value |
|-------|-------|
| Severity | Critical |
| Description | The `--rekor-url` flag or `COSIGN_REKOR_URL` must point to the TAS Rekor instance |
| Detection | Check for `--rekor-url` flag or `COSIGN_REKOR_URL` environment variable |
| Pass Condition | Rekor URL present and points to TAS Rekor endpoint |
| Remediation | Add `--rekor-url={{rekor_url}}` or set `COSIGN_REKOR_URL={{rekor_url}}` |

### SIGN-004: TUF Root Initialized

| Field | Value |
|-------|-------|
| Severity | High |
| Description | Cosign must be initialized with the TAS TUF root before signing |
| Detection | Search for `cosign initialize` command with `--mirror` and `--root` flags |
| Pass Condition | TUF initialization step present before signing step |
| Remediation | Add `cosign initialize --mirror={{tuf_url}} --root={{tuf_url}}/root.json` before signing |

### SIGN-005: Confirmation Prompt Suppressed

| Field | Value |
|-------|-------|
| Severity | Medium |
| Description | The `--yes` flag should be set for non-interactive CI/CD signing |
| Detection | Check `cosign sign` invocations for `--yes` or `-y` flag |
| Pass Condition | `--yes` flag present |
| Remediation | Add `--yes` to cosign sign commands in CI/CD pipelines |

---

## Verification Rules

### VERIFY-001: Verification Step Present

| Field | Value |
|-------|-------|
| Severity | High |
| Description | The pipeline should include a signature verification step |
| Detection | Search for `cosign verify` command in pipeline configuration |
| Pass Condition | At least one verification command found |
| Remediation | Add a verification step using `cosign verify` after deployment |

### VERIFY-002: Certificate Identity Configured

| Field | Value |
|-------|-------|
| Severity | High |
| Description | The `--certificate-identity` or `--certificate-identity-regexp` must be set for keyless verification |
| Detection | Check `cosign verify` invocations for identity flags |
| Pass Condition | Certificate identity constraint present |
| Remediation | Add `--certificate-identity={{expected_identity}}` to cosign verify |

### VERIFY-003: Certificate OIDC Issuer Configured

| Field | Value |
|-------|-------|
| Severity | High |
| Description | The `--certificate-oidc-issuer` must match the signing OIDC issuer |
| Detection | Check `cosign verify` invocations for OIDC issuer flag |
| Pass Condition | OIDC issuer constraint present and matches signing issuer |
| Remediation | Add `--certificate-oidc-issuer={{oidc_issuer}}` to cosign verify |

### VERIFY-004: Private Infrastructure Flag Set

| Field | Value |
|-------|-------|
| Severity | Medium |
| Description | For private TAS deployments, `--private-infrastructure` should be set to skip public Sigstore trust chain verification |
| Detection | Check `cosign verify` invocations for `--private-infrastructure` flag |
| Pass Condition | Flag present when using private TAS (not public Sigstore) |
| Remediation | Add `--private-infrastructure` for private TAS deployments |

---

## Policy Rules

### POLICY-001: Admission Controller Deployed

| Field | Value |
|-------|-------|
| Severity | Medium |
| Description | A policy controller should enforce signature verification on Kubernetes deployments |
| Detection | Check for `policy-controller` or `ClusterImagePolicy` CRDs on the cluster |
| Pass Condition | Policy controller installed and at least one policy defined |
| Remediation | Install the Sigstore policy-controller and create ClusterImagePolicy resources |

### POLICY-002: Image Policy Defined

| Field | Value |
|-------|-------|
| Severity | Medium |
| Description | A ClusterImagePolicy should define which images require signatures and the trusted identities |
| Detection | `kubectl get clusterimagepolicy` returns at least one resource |
| Pass Condition | Policy exists with authority and identity constraints |
| Remediation | Create a ClusterImagePolicy matching your image registry and signing identity |

---

## Supply Chain Rules

### SUPPLY-001: SBOM Generation Present

| Field | Value |
|-------|-------|
| Severity | Low |
| Description | The pipeline should generate a Software Bill of Materials (SBOM) |
| Detection | Search for SBOM tools (syft, trivy, cyclonedx) in pipeline |
| Pass Condition | SBOM generation step found |
| Remediation | Add SBOM generation using syft, trivy, or similar tool |

### SUPPLY-002: SBOM Attestation Attached

| Field | Value |
|-------|-------|
| Severity | Low |
| Description | The SBOM should be attached to the container image as an attestation via cosign |
| Detection | Search for `cosign attest` with `--predicate` and `--type` flags |
| Pass Condition | Attestation command found with SBOM predicate |
| Remediation | Add `cosign attest --predicate={{sbom_file}} --type=spdxjson` or `--type=cyclonedx` |

### SUPPLY-003: Provenance Attestation Present

| Field | Value |
|-------|-------|
| Severity | Low |
| Description | Build provenance (SLSA) should be attached as an attestation |
| Detection | Search for `cosign attest` with `--type=slsaprovenance` |
| Pass Condition | Provenance attestation step found |
| Remediation | Add SLSA provenance generation and attach via `cosign attest --type=slsaprovenance` |

---

## Gap Assessment Summary Template

After evaluating all rules, the scanner produces a gap assessment:

| Column | Description |
|--------|-------------|
| Rule ID | Rule identifier (e.g., `INFRA-001`) |
| Category | Rule category |
| Severity | Critical / High / Medium / Low |
| Status | Pass / Fail / Skipped |
| Finding | Description of what was found or missing |
| Remediation | Recommended action |

### Severity Interpretation

| Severity | Meaning |
|----------|---------|
| Critical | Blocks TAS integration — must be resolved before signing can work |
| High | Significantly impacts security or functionality — should be resolved |
| Medium | Recommended for production readiness — can be deferred |
| Low | Best practice — improves supply chain security posture |

### Confidence Scoring

The scanner computes confidence scores based on rule evaluation:

| Score Component | Weight | Calculation |
|-----------------|--------|-------------|
| Detection | 40% | Ratio of passed INFRA + OIDC rules to total |
| Compatibility | 30% | Ratio of passed SIGN + VERIFY rules to total |
| Overall | 30% | Ratio of all passed rules (including POLICY + SUPPLY) |

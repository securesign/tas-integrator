# GitLab detailed scan reference

This file preserves detailed discovery, endpoint, signing-mode, provider, blueprint, API, and example material. The main skill contains the compact operational workflow; load this reference when deeper implementation detail is needed.

### Step 1 — Connect to GitLab

1. Send `GET {{gitlab_url}}/api/v4/version` to verify connectivity and
   authentication.
2. If the request fails, report the error and stop.
3. Extract GitLab version and revision from the response.
4. Record:
   - `gitlab_version` — e.g. `17.3.1`
   - `gitlab_revision` — e.g. `abc123def`

### Step 2 — Discover Runner Configuration

1. If `project_id` is provided, send
   `GET {{gitlab_url}}/api/v4/projects/{{project_id}}/runners?type=project_type`
   to list runners assigned to the project.
2. If `group_id` is provided, send
   `GET {{gitlab_url}}/api/v4/groups/{{group_id}}/runners` to list group runners.
3. Extract from each runner: `id`, `description`, `tag_list`, `run_untagged`
   (whether it runs untagged jobs), and `status` (online/offline/paused).
4. Check for runners with relevant tags:

| Tag Pattern | Indicates |
|-------------|-----------|
| `docker`, `container` | Flag as Docker/Podman executor |
| `cosign`, `sigstore`, `signing` | Flag as signing-capable runner |
| `kubernetes`, `k8s` | Flag as Kubernetes executor |

5. Store the total runner count, executor types discovered, and whether
   at least one online runner is available.

### Step 3 — Scan Pipeline Configurations

1. For each project in scope, send
   `GET {{gitlab_url}}/api/v4/projects/{{project_id}}/repository/files/.gitlab-ci.yml/raw?ref=main`
   to retrieve the pipeline definition.
   - If `main` fails, try `master` as fallback default branch.
   - If the file is not found, try
     `GET {{gitlab_url}}/api/v4/projects/{{project_id}}` and use the
     `default_branch` field.
2. Also check for included pipeline files by parsing `include:` directives in
   the root `.gitlab-ci.yml`:
   - `include: local:` — fetch the referenced file from the same repository.
   - `include: project:` — note the reference but do not fetch cross-project
     includes (skip with a note).
   - `include: template:` — note the GitLab-provided template name.
3. Search each pipeline definition for existing TAS-related patterns:

| Pattern | Indicates |
|---------|-----------|
| `cosign sign` | Detect signing step |
| `cosign verify` | Detect verification step |
| `cosign attest` | Detect attestation step |
| `cosign initialize` | Detect TUF initialization |
| `--fulcio-url` | Detect Fulcio endpoint config |
| `--rekor-url` | Detect Rekor endpoint config |
| `--oidc-issuer` | Detect OIDC issuer config |
| `--identity-token` | Detect identity token injection |
| `--use-signing-config=false` | Detect explicit URL mode (TUF disabled) |
| `COSIGN_REKOR_URL` | Detect Rekor URL via variable |
| `SIGSTORE_ID_TOKEN` | Detect Sigstore OIDC token variable |
| `id_tokens:` | Detect GitLab native OIDC token |

4. **Detect current signing-config mode** in existing pipelines:
   - If `cosign initialize` found AND no `--use-signing-config=false` → **Current mode: TUF**
   - If `--use-signing-config=false` is present on the signing command with explicit service URL flags → **Current mode: Explicit URLs**
   - If explicit `--fulcio-url`/`--rekor-url` flags appear without `cosign initialize` → **Current mode: Explicit URLs**
   - If `cosign sign` found but neither pattern detected → **Current mode: Unknown** (legacy/non-standard)
   - If no `cosign` commands found → **Current mode: None** (no existing integration)

5. Store the total number of projects scanned, which patterns matched in
   which projects, whether signing/verification/attestation steps exist,
   whether `id_tokens:` is used for OIDC, and the **detected current mode**.

### Step 4 — Scan CI/CD Variables

1. For each project in scope, send
   `GET {{gitlab_url}}/api/v4/projects/{{project_id}}/variables` to list
   project-level CI/CD variables.
2. If `group_id` is provided, also send
   `GET {{gitlab_url}}/api/v4/groups/{{group_id}}/variables` to list
   group-level variables.
3. Extract from each variable: `key` (name), `variable_type` (`env_var` or
   `file`), `protected` (limited to protected branches), `masked` (hidden in
   job logs), and `environment_scope` (target environments).
4. Check for TAS-related variables by matching `key` against:

| Pattern | Indicates |
|---------|-----------|
| `COSIGN_REKOR_URL`, `TAS_REKOR_URL` | Detect Rekor endpoint |
| `TAS_FULCIO_URL` | Detect Fulcio endpoint |
| `TAS_TUF_URL` | Detect TUF endpoint |
| `TAS_TSA_URL` | Detect TSA endpoint |
| `TAS_OIDC_ISSUER`, `OIDC_ISSUER` | Detect OIDC issuer |
| `TAS_OIDC_CLIENT_ID`, `OIDC_CLIENT_ID` | Detect OIDC client ID |
| `COSIGN_PASSWORD` | Detect Cosign key passphrase |
| `SIGSTORE_ID_TOKEN` | Detect pre-configured Sigstore token |

5. Store which variable types are present and which are missing.

**Note:** Read only variable metadata (name, type, scope) — never read values
(see Guardrails).

### Step 5 — Detect TAS Endpoints

Discover TAS endpoint URLs. Use explicit overrides from the input parameters
if provided. Otherwise, attempt auto-detection in this order:

#### 5a — From GitLab CI/CD Variables

Map TAS endpoints from the variables discovered in Step 4:

| Variable | Set |
|----------|-----|
| `TAS_REKOR_URL` or `COSIGN_REKOR_URL` | Set `rekor_url` |
| `TAS_FULCIO_URL` | Set `fulcio_url` |
| `TAS_TUF_URL` | Set `tuf_url` |
| `TAS_TSA_URL` | Set `tsa_url` |
| `TAS_OIDC_ISSUER` or `OIDC_ISSUER` | Set `oidc_issuer` |
| `TAS_OIDC_CLIENT_ID` or `OIDC_CLIENT_ID` | Set `oidc_client_id` |

#### 5b — From Pipeline Environment Blocks

Scan `.gitlab-ci.yml` `variables:` blocks (global and per-job) for the same
variable patterns listed above.

#### 5c — From Kubernetes / OpenShift

Before asking the user for a namespace, if `kubectl` is available, inspect the
active Kubernetes context namespace read-only. If it is unset, use the
`trusted-artifact-signer` namespace. If TAS resources are found there, use that namespace. If
not, ask: "Is TAS deployed in a Kubernetes/OpenShift namespace? If so, which
one?" Use a user-provided namespace when supplied. If no namespace is
available, skip this source and continue with CI/CD, pipeline, and RHEL
discovery.

With a selected namespace, extract endpoints from individual component CRD
status fields:

```bash
REKOR_URL=$(kubectl get rekor -n {{namespace}} \
  -o jsonpath='{.items[0].status.url}')
FULCIO_URL=$(kubectl get fulcio -n {{namespace}} \
  -o jsonpath='{.items[0].status.url}')
TUF_URL=$(kubectl get tuf -n {{namespace}} \
  -o jsonpath='{.items[0].status.url}')
TSA_URL=$(kubectl get timestampauthority -n {{namespace}} \
  -o jsonpath='{.items[0].status.url}')
# Append /api/v1/timestamp if not already present (for older operator versions)
[[ -n "$TSA_URL" && "$TSA_URL" != */api/v1/timestamp ]] && TSA_URL="${TSA_URL}/api/v1/timestamp"
```

#### 5d — From RHEL Configuration

If the GitLab runner host is RHEL-based, check for the `/etc/rhtas/` directory
to detect an Ansible-deployed TAS instance.

#### 5e — Endpoint Health Checks

Run a health check for every discovered endpoint:

| Component | Health Check | Expected |
|-----------|-------------|----------|
| Fulcio | `GET {{fulcio_url}}/healthz` | HTTP 200 |
| Rekor | `GET {{rekor_url}}/api/v1/log` | HTTP 200 |
| TSA | `GET {{tsa_url}}/certchain` | HTTP 200 |
| TUF | `GET {{tuf_url}}/root.json` | HTTP 200 |

Store pass/fail for each endpoint check.

### Step 6 — Evaluate Gap Detection Rules

Run all 24 rules from [shared/knowledge-base/gap-detection-rules.md](../../../shared/knowledge-base/gap-detection-rules.md)
against the data collected in Steps 1–5. Record for each rule:

| Field | Value |
|-------|-------|
| `rule_id` | Rule identifier (e.g. `INFRA-001`) |
| `category` | Rule category code |
| `severity` | `Critical`, `High`, `Medium`, or `Low` |
| `status` | `pass`, `fail`, or `skip` |
| `details` | One-line finding |

#### Rule Evaluation Sources

| Rule Category | Evaluate Using |
|---------------|----------------|
| `INFRA` | Use Step 5 endpoint discovery and health checks |
| `OIDC` | Use Step 3 pipeline patterns (`id_tokens:`, `SIGSTORE_ID_TOKEN`) + Step 4 variables |
| `SIGN` | Use Step 3 pipeline patterns |
| `VERIFY` | Use Step 3 pipeline patterns |
| `POLICY` | Use Step 5c Kubernetes CRD check (if available) |
| `SUPPLY` | Use Step 3 pipeline patterns (SBOM tools, attestation commands) |

Mark rules as `skip` when the required data source is unavailable (e.g., no
`kubectl` access for POLICY rules).

### Step 7 — Compute Confidence Scores

Compute confidence scores using the weights from
[shared/knowledge-base/gap-detection-rules.md](../../../shared/knowledge-base/gap-detection-rules.md):

| Score | Weight | Calculation |
|-------|--------|-------------|
| Detection | 40% | Passed INFRA + OIDC rules / total INFRA + OIDC rules |
| Compatibility | 30% | Passed SIGN + VERIFY rules / total SIGN + VERIFY rules |
| Overall | 30% | All passed rules (including POLICY + SUPPLY) / total rules |

Convert the weighted percentages to labels:

| Percentage | Label |
|------------|-------|
| 80–100% | `High` |
| 50–79% | `Medium` |
| 0–49% | `Low` |

Store `overall_confidence`/`overall_details`,
`detection_confidence`/`detection_details`, and
`compatibility_confidence`/`compatibility_details`.

### Step 8 — Generate Blueprint Data

Build the blueprint data object for the `export-blueprint` skill.

#### 8a — Header Data

Set from scan results:

| Field | Source |
|-------|--------|
| `scan_timestamp` | Current ISO 8601 timestamp |
| `environment_type` | Auto-detected: `openshift`, `rhel`, or `kubernetes` |
| `cicd_platform` | `gitlab` |
| `agent_version` | Read from [.claude-plugin/plugin.json (plugin version metadata) |
| `overall_confidence` | Step 7 |
| `overall_details` | Step 7 |
| `detection_confidence` | Step 7 |
| `detection_details` | Step 7 |
| `compatibility_confidence` | Step 7 |
| `compatibility_details` | Step 7 |
| `executive_summary` | Generated summary of scan findings |

#### 8b — Platform Data

Fill placeholders for [shared/templates/gitlab-ci-blueprint.md](../../../shared/templates/gitlab-ci-blueprint.md):

| Placeholder | Source |
|-------------|--------|
| `gitlab_version_status` | Set from Step 1 — `OK` if detected, `Unknown` otherwise |
| `gitlab_version_details` | Set from Step 1 — version string |
| `runner_status` | Set from Step 2 — `OK` if at least one online Docker/K8s runner |
| `runner_details` | Set from Step 2 — include runner count and executor types |
| `network_status` | Set from Step 5e — `OK` if all endpoints reachable |
| `network_details` | Set from Step 5e — summarize reachable/unreachable endpoints |
| `tas_server_status` | Set from Step 5 — `OK` if at least Fulcio + Rekor detected |
| `tas_server_details` | Set from Step 5 — include deployment method and endpoints |
| `cosign_cli_status` | Set from Step 6 INFRA-006 — `OK` if passed, `Unknown` if skipped, `Missing` if failed |
| `cosign_cli_details` | Set from Step 6 INFRA-006 — version string if passed; `Cannot verify remotely — ensure cosign is installed on CI runner nodes` if skipped; `cosign CLI not found — install via package manager, container image, or binary download` if failed |
| `oidc_status` | Set from Step 6 OIDC rules — `OK` if OIDC-001 and OIDC-002 pass |
| `oidc_details` | Set from Step 6 — include OIDC issuer and client ID if detected |
| `variable_name` | Set from Step 4 — add one row per required CI/CD variable |
| `variable_type` | Set from Step 4 — use `env_var` or `file` |
| `variable_scope` | Set from Step 4 — use environment scope |
| `variable_protected` | Set from Step 4 — use `Yes` or `No` |
| `variable_masked` | Set from Step 4 — use `Yes` or `No` |
| `variable_description` | Set from Step 4 — describe variable purpose |
| `variable_configuration_steps` | Generate `glab variable set` instructions for each variable |

##### Pipeline & Validation Placeholders

| Placeholder | Source |
|-------------|--------|
| `signing_job_snippet` | Generate `.gitlab-ci.yml` signing job using detected endpoints |
| `verification_job_snippet` | Generate `.gitlab-ci.yml` verification job |
| `attestation_job_snippet` | Generate `.gitlab-ci.yml` attestation job |
| `full_pipeline_example` | Generate complete `.gitlab-ci.yml` combining all jobs |
| `validation_command` | Add one row per validation command |
| `validation_purpose` | Describe command purpose |
| `validation_expected` | Describe expected output |
| `checklist_item` | Add one row per post-integration checklist item |

#### `.gitlab-ci.yml` Snippet Generation

Generate YAML pipeline snippets using patterns from
[shared/knowledge-base/cosign-signing-patterns.md](../../../shared/knowledge-base/cosign-signing-patterns.md) and
[shared/knowledge-base/oidc-setup.md](../../../shared/knowledge-base/oidc-setup.md) (GitLab CI section).

Prefer GitLab's native `id_tokens` keyword for OIDC token acquisition — unlike
Jenkins, no external Keycloak token fetch is needed.

---

**Mode Selection: TUF Mode vs Explicit URL Mode**

Choose which mode to generate based on existing configuration, TUF availability, and user preference.

**Priority order (highest to lowest):**

| Priority | Condition | Mode | Reason |
|----------|-----------|------|--------|
| 1 | User explicitly asks for `--use-signing-config=false` or "explicit URLs" | **Explicit URL Mode** | Honor user override request |
| 2 | Existing pipelines use TUF mode (`cosign initialize` detected) | **TUF Mode** | Preserve current configuration |
| 3 | Existing pipelines use Explicit URL mode (`--use-signing-config=false` detected) | **Explicit URL Mode** | Preserve current configuration |
| 4 | No existing integration + TUF endpoint detected | **TUF Mode (Recommended)** | Greenfield - use best practice |
| 5 | No existing integration + TUF NOT detected | **Explicit URL Mode** | TUF unavailable, fallback required |

**Decision Logic:**

1. Check if user explicitly requested explicit URL mode in their query (see detection patterns below)
   - If yes → **Use Explicit URL Mode** (override everything)
2. Check `current_mode` from Step 3 pipeline scanning:
   - If `TUF` → **Use TUF Mode** (preserve existing)
   - If `Explicit URLs` → **Use Explicit URL Mode** (preserve existing)
   - If `Unknown` or `None` → Continue to step 3
3. Check if `tuf_url` was discovered in Step 5:
   - If yes → **Use TUF Mode** (greenfield recommendation)
   - If no → **Use Explicit URL Mode** (fallback)

**User Query Detection:** Look for these phrases to detect explicit URL mode override:
- "use explicit URLs"
- "without TUF"
- "--use-signing-config=false"
- "don't use TUF"
- "explicit service URLs"
- "disable signing config"

**Mode Recommendation Output:**

Use the shared [signing-mode blueprint section](../../../shared/knowledge-base/signing-mode-blueprint.md)
for the mode comparison, placeholders, and recommendation wording. Set
`{{ci_platform}}` to `GitLab runners` and retain the GitLab-specific pipeline
snippets below.

---

**TUF Mode Snippets:**

Generate the signing job — run `cosign initialize` then `cosign sign` with
GitLab's native `id_tokens`:

```yaml
sign-image:
  stage: sign
  image: registry.redhat.io/rhtas/cosign-rhel9:latest
  id_tokens:
    SIGSTORE_ID_TOKEN:
      aud: trusted-artifact-signer
  variables:
    TUF_URL: ${TAS_TUF_URL}
    TAS_TUF_ROOT_CHECKSUM: ${TAS_TUF_ROOT_CHECKSUM}
    FULCIO_URL: ${TAS_FULCIO_URL}
    REKOR_URL: ${TAS_REKOR_URL}
    OIDC_ISSUER: ${TAS_OIDC_ISSUER}
  script:
    - ': "${TAS_TUF_ROOT_CHECKSUM:?Set the pinned TAS_TUF_ROOT_CHECKSUM CI/CD variable}"'
    - cosign initialize
        --mirror="${TUF_URL}"
        --root="${TUF_URL}/1.root.json"
        --root-checksum="${TAS_TUF_ROOT_CHECKSUM}"
    - cosign sign
        --fulcio-url=${FULCIO_URL}
        --rekor-url=${REKOR_URL}
        --oidc-issuer=${OIDC_ISSUER}
        --oidc-client-id=trusted-artifact-signer
        --identity-token=${SIGSTORE_ID_TOKEN}
        --yes
        ${IMAGE_REFERENCE}
```

Generate the verification job — run `cosign verify` with certificate identity:

```yaml
verify-image:
  stage: verify
  image: registry.redhat.io/rhtas/cosign-rhel9:latest
  variables:
    REKOR_URL: ${TAS_REKOR_URL}
    OIDC_ISSUER: ${TAS_OIDC_ISSUER}
  script:
    - cosign verify
        --rekor-url=${REKOR_URL}
        --certificate-identity=${EXPECTED_IDENTITY}
        --certificate-oidc-issuer=${OIDC_ISSUER}
        ${IMAGE_REFERENCE}
```

Generate the attestation job — run `cosign attest` with SBOM predicates:

```yaml
attest-image:
  stage: sign
  image: registry.redhat.io/rhtas/cosign-rhel9:latest
  id_tokens:
    SIGSTORE_ID_TOKEN:
      aud: trusted-artifact-signer
  variables:
    FULCIO_URL: ${TAS_FULCIO_URL}
    REKOR_URL: ${TAS_REKOR_URL}
    OIDC_ISSUER: ${TAS_OIDC_ISSUER}
  script:
    - cosign attest
        --fulcio-url=${FULCIO_URL}
        --rekor-url=${REKOR_URL}
        --oidc-issuer=${OIDC_ISSUER}
        --oidc-client-id=trusted-artifact-signer
        --identity-token=${SIGSTORE_ID_TOKEN}
        --predicate=${SBOM_FILE}
        --type=spdxjson
        --yes
        ${IMAGE_REFERENCE}
```

---

**Explicit URL Mode Snippets (when TUF not available or user requests it):**

If TUF is not available or user explicitly requests `--use-signing-config=false`,
generate these snippets instead (explicit URL flags with
`--use-signing-config=false`).

**Note:** Even without TUF, you still need to extract and trust the TAS server CA
certificate for HTTPS calls. Add this to the `before_script` of signing/verification jobs:

```yaml
before_script:
  - |
    # Extract TAS server CA certificate for TLS verification
    TAS_HOST=$(echo "${TAS_FULCIO_URL}" | sed 's|^https://||' | cut -d/ -f1)
    echo | openssl s_client -showcerts -connect "${TAS_HOST}:443" 2>/dev/null \
        | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > /tmp/tas-ca.crt
    export SSL_CERT_FILE=/tmp/tas-ca.crt
    export CURL_CA_BUNDLE=/tmp/tas-ca.crt
```

**Signing job (Explicit URL mode):**

```yaml
sign-image:
  stage: sign
  image: registry.redhat.io/rhtas/cosign-rhel9:latest
  id_tokens:
    SIGSTORE_ID_TOKEN:
      aud: trusted-artifact-signer
  variables:
    TAS_FULCIO_URL: ${TAS_FULCIO_URL}
    TAS_REKOR_URL: ${TAS_REKOR_URL}
    TAS_OIDC_ISSUER: ${TAS_OIDC_ISSUER}
  before_script:
    - |
      # Extract TAS server CA certificate
      TAS_HOST=$(echo "${TAS_FULCIO_URL}" | sed 's|^https://||' | cut -d/ -f1)
      echo | openssl s_client -showcerts -connect "${TAS_HOST}:443" 2>/dev/null \
          | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > /tmp/tas-ca.crt
      export SSL_CERT_FILE=/tmp/tas-ca.crt
      export CURL_CA_BUNDLE=/tmp/tas-ca.crt
  script:
    - cosign sign
        --use-signing-config=false
        --fulcio-url=${TAS_FULCIO_URL}
        --rekor-url=${TAS_REKOR_URL}
        --oidc-issuer=${TAS_OIDC_ISSUER}
        --oidc-client-id=trusted-artifact-signer
        --identity-token=${SIGSTORE_ID_TOKEN}
        --yes
        ${IMAGE_REFERENCE}
```

**Verification job (Explicit URL mode):**

```yaml
verify-image:
  stage: verify
  image: registry.redhat.io/rhtas/cosign-rhel9:latest
  variables:
    TAS_REKOR_URL: ${TAS_REKOR_URL}
    TAS_OIDC_ISSUER: ${TAS_OIDC_ISSUER}
  before_script:
    - |
      # Extract TAS server CA certificate
      TAS_HOST=$(echo "${TAS_REKOR_URL}" | sed 's|^https://||' | cut -d/ -f1)
      echo | openssl s_client -showcerts -connect "${TAS_HOST}:443" 2>/dev/null \
          | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > /tmp/tas-ca.crt
      export SSL_CERT_FILE=/tmp/tas-ca.crt
      export CURL_CA_BUNDLE=/tmp/tas-ca.crt
  script:
    - cosign verify
        --use-signing-config=false
        --rekor-url=${TAS_REKOR_URL}
        --certificate-identity=${EXPECTED_IDENTITY}
        --certificate-oidc-issuer=${TAS_OIDC_ISSUER}
        ${IMAGE_REFERENCE}
```

**Attestation job (Explicit URL mode):**

```yaml
attest-image:
  stage: sign
  image: registry.redhat.io/rhtas/cosign-rhel9:latest
  id_tokens:
    SIGSTORE_ID_TOKEN:
      aud: trusted-artifact-signer
  variables:
    TAS_FULCIO_URL: ${TAS_FULCIO_URL}
    TAS_REKOR_URL: ${TAS_REKOR_URL}
    TAS_OIDC_ISSUER: ${TAS_OIDC_ISSUER}
  before_script:
    - |
      # Extract TAS server CA certificate
      TAS_HOST=$(echo "${TAS_FULCIO_URL}" | sed 's|^https://||' | cut -d/ -f1)
      echo | openssl s_client -showcerts -connect "${TAS_HOST}:443" 2>/dev/null \
          | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > /tmp/tas-ca.crt
      export SSL_CERT_FILE=/tmp/tas-ca.crt
      export CURL_CA_BUNDLE=/tmp/tas-ca.crt
  script:
    - cosign attest
        --use-signing-config=false
        --fulcio-url=${TAS_FULCIO_URL}
        --rekor-url=${TAS_REKOR_URL}
        --oidc-issuer=${TAS_OIDC_ISSUER}
        --oidc-client-id=trusted-artifact-signer
        --identity-token=${SIGSTORE_ID_TOKEN}
        --predicate=${SBOM_FILE}
        --type=spdxjson
        --yes
        ${IMAGE_REFERENCE}
```

**Note:** Explicit URL mode requires setting all service URLs as CI/CD variables
(TAS_FULCIO_URL, TAS_REKOR_URL, TAS_TSA_URL, TAS_OIDC_ISSUER).

---

Substitute detected endpoint URLs for variable references when known.
Keep variable references when endpoints are not detected so the user can
configure them manually.

#### 8c — Gaps Data

Include the evaluated gap results from Step 6 as the `gaps` array.

#### 8d — Endpoints Data

Include the discovered endpoints from Step 5 as the `endpoints` object.

## GitLab API Reference

Send `GET` requests with the `/api/v4` prefix for JSON responses.

| Endpoint | Use to |
|----------|--------|
| `GET /api/v4/version` | Retrieve GitLab version and revision |
| `GET /api/v4/projects/:id` | Retrieve project details including default branch |
| `GET /api/v4/projects/:id/repository/files/:path/raw?ref=:branch` | Read file content from repository |
| `GET /api/v4/projects/:id/variables` | List project-level CI/CD variables |
| `GET /api/v4/projects/:id/runners?type=project_type` | List project runners |
| `GET /api/v4/groups/:id/variables` | List group-level CI/CD variables |
| `GET /api/v4/groups/:id/runners` | List group runners |
| `GET /api/v4/groups/:id/projects` | List projects in a group |

Paginate list endpoints using `page` and `per_page` query parameters (default
20, max 100). Read `x-next-page` response headers to iterate through pages.

---

## GitLab OIDC vs Jenkins OIDC

Prefer GitLab CI's **native OIDC tokens** via the `id_tokens` keyword to
eliminate the external token fetch required by Jenkins. Compare the approaches:

| Aspect | GitLab CI | Jenkins |
|--------|-----------|---------|
| Token source | Use native `id_tokens` keyword | Run external Keycloak `curl` call |
| Configuration | Set `id_tokens: SIGSTORE_ID_TOKEN: aud: trusted-artifact-signer` | Set Keycloak URL, realm, client ID, client secret |
| Credentials needed | None (GitLab-managed) | Configure Keycloak service account credentials |
| Fulcio issuer type | Set to `gitlab-pipeline` | Set to `email` (via Keycloak) |
| Token variable | Read `SIGSTORE_ID_TOKEN` (auto-populated) | Read `IDENTITY_TOKEN` (manually fetched) |

Check for both the modern `id_tokens:` keyword and the legacy `CI_JOB_JWT_V2`
/ `CI_JOB_JWT` variables.

---

## Examples

### Basic Scan (Single Project)

Scan a single project and display results in the conversation:

```
/tas-integrator:scan-gitlab

GitLab URL: https://gitlab.example.com
Token: <your-gitlab-token>
Project ID: my-group/my-project
```

### Scan a Group

Scan all projects in a group and display results:

```
/tas-integrator:scan-gitlab

GitLab URL: https://gitlab.example.com
Token: <your-gitlab-token>
Group ID: 42
```

### Scan with TAS Namespace

Auto-detect TAS endpoints from the Securesign CR in the namespace:

```
/tas-integrator:scan-gitlab

GitLab URL: https://gitlab.example.com
Token: <your-gitlab-token>
Project ID: 123
Namespace: trusted-artifact-signer
```

### Scan with Explicit Endpoints and YAML Save

Override endpoint URLs and write the blueprint as YAML:

```
/tas-integrator:scan-gitlab --output=save --format=yaml

GitLab URL: https://gitlab.example.com
Token: <your-gitlab-token>
Project ID: my-group/my-project
Rekor URL: https://rekor.tas.example.com
Fulcio URL: https://fulcio.tas.example.com
TUF URL: https://tuf.tas.example.com
```

### Scan with Display and Save

Display the blueprint and save it to a custom output path:

```
/tas-integrator:scan-gitlab --output=both --output_path=./reports/gitlab-scan.md

GitLab URL: https://gitlab.example.com
Token: <your-gitlab-token>
Group ID: 42
Namespace: trusted-artifact-signer
```

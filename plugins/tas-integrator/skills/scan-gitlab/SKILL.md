---
name: scan-gitlab
description: |
  Scan a GitLab CI environment for TAS integration readiness and generate an integration blueprint.
---

# scan-gitlab

Scans a GitLab CI environment for TAS integration readiness. Connects to the
GitLab API (read-only), inspects `.gitlab-ci.yml` pipeline configurations, CI/CD
variables, project settings, and network reachability. Evaluates gap detection
rules, generates a blueprint using the GitLab CI template with `.gitlab-ci.yml`
job snippets, assigns confidence scores, and presents the result for review
before export.

---

## Invocation

```
/tas-integrator:scan-gitlab
```

---

## Guardrails

This skill operates in **read-only** mode. It MUST NOT modify the target GitLab
instance in any way.

| Constraint | Enforcement |
|------------|-------------|
| HTTP methods | `GET` only — no `POST`, `PUT`, `DELETE`, or `PATCH` requests to the GitLab API |
| Access token | Used solely for API authentication — never stored, logged, or written to files |
| GitLab configuration | Never modified — no pipeline edits, variable creation, or settings changes |
| File system | Only writes the final blueprint file (when `save` or `both` output mode is used) |
| Network | Only connects to the GitLab API URL and TAS endpoint URLs for health checks |

The skill MUST NOT attempt to read CI/CD variable values — the GitLab API does
not expose values to `read_api` scope tokens, and attempting to do so would
violate the read-only guardrail. Only variable metadata (name, type, scope) is
read.

If any step would require a non-`GET` request to GitLab, skip that check and
record the gap as `skip` with a note explaining that write access is not
permitted.

---

## Inputs

The caller provides GitLab connection details and optional TAS endpoint
overrides.

### Required

| Parameter | Type | Description |
|-----------|------|-------------|
| `gitlab_url` | string | GitLab instance base URL (e.g. `https://gitlab.example.com`) |

### Optional

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `gitlab_token` | string | — | Personal access token or project/group access token with `read_api` scope |
| `project_id` | string | — | GitLab project ID or URL-encoded path (e.g. `group/project`) to scan a single project |
| `group_id` | string | — | GitLab group ID to scan all projects in the group |
| `namespace` | string | — | Kubernetes/OpenShift namespace where TAS is deployed |
| `rekor_url` | string | auto-detect | Override Rekor endpoint URL |
| `fulcio_url` | string | auto-detect | Override Fulcio endpoint URL |
| `tuf_url` | string | auto-detect | Override TUF endpoint URL |
| `tsa_url` | string | auto-detect | Override TSA endpoint URL |
| `oidc_issuer` | string | auto-detect | Override OIDC issuer URL |
| `oidc_client_id` | string | auto-detect | Override OIDC client ID |
| `output` | string | `display` | Output mode: `display`, `save`, or `both` |
| `format` | string | `markdown` | Output format: `markdown` or `yaml` |
| `output_path` | string | auto-generated | File path for `save` and `both` modes |

### Authentication

If `gitlab_token` is provided, use it as a private token header for all GitLab
API requests:

```
PRIVATE-TOKEN: <gitlab_token>
```

If a token is not provided, attempt unauthenticated access. If a `401` or `403`
response is received, prompt the user for a token before retrying.

### Scope

- If `project_id` is provided, scan only that project.
- If `group_id` is provided, list all projects in the group and scan each one.
- If neither is provided, prompt the user to specify a project or group.

---

## Processing Steps

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
3. For each runner, extract:
   - `id` — runner ID
   - `description` — runner description
   - `tag_list` — runner tags
   - `run_untagged` — whether it runs untagged jobs
   - `status` — online/offline/paused
4. Check for runners with relevant tags:

| Tag Pattern | Indicates |
|-------------|-----------|
| `docker`, `container` | Docker/Podman executor available |
| `cosign`, `sigstore`, `signing` | Signing-capable runner |
| `kubernetes`, `k8s` | Kubernetes executor |

5. Record:
   - Total number of runners
   - Runner executor types
   - Whether at least one online runner is available

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
| `cosign sign` | Signing step present |
| `cosign verify` | Verification step present |
| `cosign attest` | Attestation step present |
| `cosign initialize` | TUF initialization present |
| `--fulcio-url` | Fulcio endpoint configured |
| `--rekor-url` | Rekor endpoint configured |
| `--oidc-issuer` | OIDC issuer configured |
| `--identity-token` | Identity token injection |
| `COSIGN_REKOR_URL` | Rekor URL via variable |
| `SIGSTORE_ID_TOKEN` | Sigstore OIDC token variable |
| `id_tokens:` | GitLab native OIDC token declaration |

4. Record:
   - Total number of projects scanned
   - Which patterns were found and in which projects
   - Whether any signing, verification, or attestation steps exist
   - Whether `id_tokens:` keyword is used for OIDC

### Step 4 — Scan CI/CD Variables

1. For each project in scope, send
   `GET {{gitlab_url}}/api/v4/projects/{{project_id}}/variables` to list
   project-level CI/CD variables.
2. If `group_id` is provided, also send
   `GET {{gitlab_url}}/api/v4/groups/{{group_id}}/variables` to list
   group-level variables.
3. For each variable, extract:
   - `key` — variable name
   - `variable_type` — `env_var` or `file`
   - `protected` — whether limited to protected branches
   - `masked` — whether masked in job logs
   - `environment_scope` — which environments the variable applies to
4. Check for TAS-related variables by matching `key` against:

| Pattern | Indicates |
|---------|-----------|
| `COSIGN_REKOR_URL`, `TAS_REKOR_URL` | Rekor endpoint configured |
| `TAS_FULCIO_URL` | Fulcio endpoint configured |
| `TAS_TUF_URL` | TUF endpoint configured |
| `TAS_TSA_URL` | TSA endpoint configured |
| `TAS_OIDC_ISSUER`, `OIDC_ISSUER` | OIDC issuer configured |
| `TAS_OIDC_CLIENT_ID`, `OIDC_CLIENT_ID` | OIDC client ID configured |
| `COSIGN_PASSWORD` | Cosign key passphrase stored |
| `SIGSTORE_ID_TOKEN` | Pre-configured Sigstore token |

5. Record which variable types are present and which are missing.

**Note:** The skill reads only variable metadata (name, type, scope), not values
(see Guardrails).

### Step 5 — Detect TAS Endpoints

Attempt to discover TAS endpoint URLs. Use explicit overrides from the input
parameters if provided. Otherwise, try auto-detection in this order:

#### 5a — From GitLab CI/CD Variables

Use the variables discovered in Step 4 to map TAS endpoints:

| Variable | Maps To |
|----------|---------|
| `TAS_REKOR_URL` or `COSIGN_REKOR_URL` | `rekor_url` |
| `TAS_FULCIO_URL` | `fulcio_url` |
| `TAS_TUF_URL` | `tuf_url` |
| `TAS_TSA_URL` | `tsa_url` |
| `TAS_OIDC_ISSUER` or `OIDC_ISSUER` | `oidc_issuer` |
| `TAS_OIDC_CLIENT_ID` or `OIDC_CLIENT_ID` | `oidc_client_id` |

#### 5b — From Pipeline Environment Blocks

Search `.gitlab-ci.yml` `variables:` blocks (global and per-job) for the same
variable patterns listed above.

#### 5c — From Kubernetes / OpenShift (if `namespace` provided)

If a `namespace` is provided and `kubectl` is available, discover endpoints
from the Securesign CR status fields:

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

#### 5d — From RHEL Configuration

If the GitLab runner host is RHEL-based, check for `/etc/rhtas/` directory
presence as an indicator of an Ansible-deployed TAS instance.

#### 5e — Endpoint Health Checks

For every discovered endpoint, validate reachability:

| Component | Health Check | Expected |
|-----------|-------------|----------|
| Fulcio | `GET {{fulcio_url}}/healthz` | HTTP 200 |
| Rekor | `GET {{rekor_url}}/api/v1/log` | HTTP 200 |
| TSA | `GET {{tsa_url}}/api/v1/timestamp/certchain` | HTTP 200 |
| TUF | `GET {{tuf_url}}/root.json` | HTTP 200 |

Record pass/fail for each endpoint health check.

### Step 6 — Evaluate Gap Detection Rules

Evaluate all 24 rules from `shared/knowledge-base/gap-detection-rules.md`
against the data collected in Steps 1–5. For each rule, record:

| Field | Value |
|-------|-------|
| `rule_id` | Rule identifier (e.g. `INFRA-001`) |
| `category` | Rule category code |
| `severity` | `Critical`, `High`, `Medium`, or `Low` |
| `status` | `pass`, `fail`, or `skip` |
| `details` | One-line finding |

#### Rule Evaluation Sources

| Rule Category | Data Source |
|---------------|------------|
| `INFRA` | Step 5 endpoint discovery and health checks |
| `OIDC` | Step 3 pipeline patterns (`id_tokens:`, `SIGSTORE_ID_TOKEN`) + Step 4 variables |
| `SIGN` | Step 3 pipeline patterns |
| `VERIFY` | Step 3 pipeline patterns |
| `POLICY` | Step 5c Kubernetes CRD check (if available) |
| `SUPPLY` | Step 3 pipeline patterns (SBOM tools, attestation commands) |

Rules that cannot be evaluated because the required data source is unavailable
(e.g., no `kubectl` access for POLICY rules) are recorded as `skip`.

### Step 7 — Compute Confidence Scores

Calculate confidence scores using the weights defined in
`shared/knowledge-base/gap-detection-rules.md`:

| Score | Weight | Calculation |
|-------|--------|-------------|
| Detection | 40% | Passed INFRA + OIDC rules / total INFRA + OIDC rules |
| Compatibility | 30% | Passed SIGN + VERIFY rules / total SIGN + VERIFY rules |
| Overall | 30% | All passed rules (including POLICY + SUPPLY) / total rules |

Map the weighted percentages to labels:

| Percentage | Label |
|------------|-------|
| 80–100% | `High` |
| 50–79% | `Medium` |
| 0–49% | `Low` |

Record:
- `overall_confidence` and `overall_details`
- `detection_confidence` and `detection_details`
- `compatibility_confidence` and `compatibility_details`

### Step 8 — Generate Blueprint Data

Assemble the blueprint data object that the `export-blueprint` skill consumes.

#### 8a — Header Data

Populate from scan results:

| Field | Source |
|-------|--------|
| `scan_timestamp` | Current ISO 8601 timestamp |
| `environment_type` | Auto-detected: `openshift`, `rhel`, or `kubernetes` |
| `cicd_platform` | `gitlab` |
| `agent_version` | Version from `.claude-plugin/plugin.json` |
| `overall_confidence` | Step 7 |
| `overall_details` | Step 7 |
| `detection_confidence` | Step 7 |
| `detection_details` | Step 7 |
| `compatibility_confidence` | Step 7 |
| `compatibility_details` | Step 7 |
| `executive_summary` | Generated summary of scan findings |

#### 8b — Platform Data

Populate placeholders for `shared/templates/gitlab-ci-blueprint.md`:

| Placeholder | Source |
|-------------|--------|
| `gitlab_version_status` | Step 1 — `OK` if version detected, `Unknown` otherwise |
| `gitlab_version_details` | Step 1 — version string |
| `runner_status` | Step 2 — `OK` if at least one online runner with Docker/K8s executor |
| `runner_details` | Step 2 — runner count and executor types |
| `network_status` | Step 5e — `OK` if all endpoints reachable |
| `network_details` | Step 5e — summary of reachable/unreachable endpoints |
| `tas_server_status` | Step 5 — `OK` if at least Fulcio + Rekor detected |
| `tas_server_details` | Step 5 — deployment method and endpoints |
| `oidc_status` | Step 6 OIDC rules — `OK` if OIDC-001 and OIDC-002 pass |
| `oidc_details` | Step 6 — OIDC issuer and client ID if detected |
| `variable_name` | Step 4 — one row per required CI/CD variable |
| `variable_type` | Step 4 — `env_var` or `file` |
| `variable_scope` | Step 4 — environment scope |
| `variable_protected` | Step 4 — `Yes` or `No` |
| `variable_masked` | Step 4 — `Yes` or `No` |
| `variable_description` | Step 4 — variable purpose |
| `variable_configuration_steps` | Generated variable setup instructions |
| `signing_job_snippet` | `.gitlab-ci.yml` signing job using detected endpoints |
| `verification_job_snippet` | `.gitlab-ci.yml` verification job |
| `attestation_job_snippet` | `.gitlab-ci.yml` attestation job |
| `full_pipeline_example` | Complete `.gitlab-ci.yml` combining all jobs |
| `validation_command` | One row per validation command |
| `validation_purpose` | Command purpose |
| `validation_expected` | Expected output |
| `checklist_item` | One row per post-integration checklist item |

#### `.gitlab-ci.yml` Snippet Generation

Use patterns from `shared/knowledge-base/cosign-signing-patterns.md` and
`shared/knowledge-base/oidc-setup.md` (GitLab CI section) to generate YAML
pipeline snippets.

GitLab CI provides native OIDC tokens via the `id_tokens` keyword — this is the
preferred token acquisition method, unlike Jenkins which requires an external
Keycloak token fetch.

**Signing job:**

```yaml
sign-image:
  stage: sign
  image: registry.redhat.io/rhtas/cosign-rhel9:latest
  id_tokens:
    SIGSTORE_ID_TOKEN:
      aud: trusted-artifact-signer
  variables:
    TUF_URL: ${TAS_TUF_URL}
    FULCIO_URL: ${TAS_FULCIO_URL}
    REKOR_URL: ${TAS_REKOR_URL}
    OIDC_ISSUER: ${TAS_OIDC_ISSUER}
  script:
    - cosign initialize
        --mirror=${TUF_URL}
        --root=${TUF_URL}/root.json
    - cosign sign
        --fulcio-url=${FULCIO_URL}
        --rekor-url=${REKOR_URL}
        --oidc-issuer=${OIDC_ISSUER}
        --oidc-client-id=trusted-artifact-signer
        --identity-token=${SIGSTORE_ID_TOKEN}
        --yes
        ${IMAGE_REFERENCE}
```

**Verification job:**

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

**Attestation job:**

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

Substitute detected endpoint URLs for the variable references when endpoints are
known. When endpoints are not detected, keep the variable references so the user
can configure them.

#### 8c — Gaps Data

Pass the evaluated gap results from Step 6 as the `gaps` array.

#### 8d — Endpoints Data

Pass the discovered endpoints from Step 5 as the `endpoints` object.

### Step 9 — Present for Review

Before exporting the blueprint, present a summary to the user for review:

```
## Scan Summary

| Field | Value |
|-------|-------|
| GitLab URL | {{gitlab_url}} |
| GitLab Version | {{gitlab_version}} |
| Projects Scanned | {{total_projects}} |
| Runners Found | {{total_runners}} |
| TAS Deployment | {{deployment_method}} or Not detected |

## Confidence Scores

| Category | Score | Details |
|----------|-------|---------|
| Overall | {{overall_confidence}} | {{overall_details}} |
| Detection | {{detection_confidence}} | {{detection_details}} |
| Compatibility | {{compatibility_confidence}} | {{compatibility_details}} |

## Gap Summary

- **Passed:** X rules
- **Failed:** Y rules
- **Skipped:** Z rules
- **Critical gaps:** list of failing critical rule IDs or "None"

## Detected Endpoints

| Component | URL | Status |
|-----------|-----|--------|
| Fulcio | {{fulcio_url}} or Not detected | Healthy / Unreachable / — |
| Rekor | {{rekor_url}} or Not detected | Healthy / Unreachable / — |
| TSA | {{tsa_url}} or Not detected | Healthy / Unreachable / — |
| TUF | {{tuf_url}} or Not detected | Healthy / Unreachable / — |
```

Ask the user:

> "Review the scan results above. Would you like to proceed with blueprint
> generation, adjust any findings, or re-scan with different parameters?"

Wait for user confirmation before proceeding to Step 10.

### Step 10 — Export Blueprint

Invoke the `export-blueprint` skill with the assembled blueprint data object
from Step 8, passing the output parameters specified by the user:

```
/tas-integrator:export-blueprint --output={{output}} --format={{format}}

Blueprint data:
- header: (assembled in Step 8a)
- platform: (assembled in Step 8b)
- gaps: (assembled in Step 8c)
- endpoints: (assembled in Step 8d)
```

The export-blueprint skill handles template rendering, gap assessment summary,
validation command summary, metadata block, and output formatting.

---

## GitLab API Reference

All API calls use `GET` requests with the `/api/v4` prefix for JSON responses.

| Endpoint | Purpose |
|----------|---------|
| `GET /api/v4/version` | GitLab version and revision |
| `GET /api/v4/projects/:id` | Project details including default branch |
| `GET /api/v4/projects/:id/repository/files/:path/raw?ref=:branch` | File content from repository |
| `GET /api/v4/projects/:id/variables` | Project-level CI/CD variables |
| `GET /api/v4/projects/:id/runners?type=project_type` | Project runners |
| `GET /api/v4/groups/:id/variables` | Group-level CI/CD variables |
| `GET /api/v4/groups/:id/runners` | Group runners |
| `GET /api/v4/groups/:id/projects` | List projects in a group |

All list endpoints support pagination via `page` and `per_page` query parameters
(default 20, max 100). Follow `x-next-page` response headers for pagination.

---

## Knowledge Base References

This skill draws from the following knowledge base files during scanning:

| File | Usage |
|------|-------|
| `shared/knowledge-base/gap-detection-rules.md` | Rule definitions for all 24 gap checks across 6 categories |
| `shared/knowledge-base/cosign-signing-patterns.md` | Cosign CLI flags and command patterns for `.gitlab-ci.yml` snippet generation |
| `shared/knowledge-base/tas-endpoint-config.md` | Endpoint URL formats, health check commands, and CI/CD variable mapping |
| `shared/knowledge-base/oidc-setup.md` | OIDC issuer types, GitLab native `id_tokens`, and token injection patterns |
| `shared/knowledge-base/deployment-patterns.md` | OpenShift operator and RHEL Ansible deployment detection indicators |

---

## Error Handling

| Condition | Behaviour |
|-----------|-----------|
| GitLab URL unreachable | Report connection error, stop |
| Authentication required but token not provided | Prompt user for token, retry |
| Authentication failed (401/403) | Report invalid or insufficient token scope, stop |
| Token lacks `read_api` scope | Report required scope, stop |
| `.gitlab-ci.yml` not found | Record as gap (no pipeline configured), continue |
| Included pipeline file not readable | Skip that include, continue scanning root config |
| Cross-project `include:` detected | Skip with note (read-only, no cross-project access), continue |
| CI/CD variables not accessible | Record variable scan as skipped, continue |
| Runners not accessible | Record runner scan as skipped, continue |
| TAS endpoints not detected | Use `{{placeholder}}` markers in blueprint, warn user |
| `kubectl` not available for namespace scan | Skip operator detection, continue with other methods |
| Health check timeout (>10s) | Record endpoint as unreachable, continue |
| No pipeline jobs found | Record as gap (no signing steps), continue |
| Group contains >100 projects | Scan first 100 with warning, suggest narrowing scope |

---

## GitLab OIDC vs Jenkins OIDC

GitLab CI provides **native OIDC tokens** via the `id_tokens` keyword, making
token acquisition significantly simpler than Jenkins:

| Aspect | GitLab CI | Jenkins |
|--------|-----------|---------|
| Token source | Native `id_tokens` keyword | External Keycloak `curl` call |
| Configuration | `id_tokens: SIGSTORE_ID_TOKEN: aud: trusted-artifact-signer` | Keycloak URL, realm, client ID, client secret |
| Credentials needed | None (GitLab-managed) | Keycloak service account credentials |
| Fulcio issuer type | `gitlab-pipeline` | `email` (via Keycloak) |
| Token variable | `SIGSTORE_ID_TOKEN` (auto-populated) | `IDENTITY_TOKEN` (manually fetched) |

The scanner checks for both the modern `id_tokens:` keyword and the legacy
`CI_JOB_JWT_V2` / `CI_JOB_JWT` variables.

---

## Examples

### Basic Scan (Single Project)

```
/tas-integrator:scan-gitlab

GitLab URL: https://gitlab.example.com
Token: <your-gitlab-token>
Project ID: my-group/my-project
```

### Scan a Group

```
/tas-integrator:scan-gitlab

GitLab URL: https://gitlab.example.com
Token: <your-gitlab-token>
Group ID: 42
```

### Scan with TAS Namespace

```
/tas-integrator:scan-gitlab

GitLab URL: https://gitlab.example.com
Token: <your-gitlab-token>
Project ID: 123
Namespace: trusted-artifact-signer
```

### Scan with Explicit Endpoints and YAML Save

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

```
/tas-integrator:scan-gitlab --output=both --output_path=./reports/gitlab-scan.md

GitLab URL: https://gitlab.example.com
Token: <your-gitlab-token>
Group ID: 42
Namespace: trusted-artifact-signer
```

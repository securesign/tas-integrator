---
name: scan-gitlab
description: |
  Scan a GitLab CI environment for TAS integration readiness and generate an integration blueprint.
---

# scan-gitlab

Scan a GitLab CI environment for TAS integration readiness. Connect to the
GitLab API (read-only), inspect `.gitlab-ci.yml` pipeline configurations, CI/CD
variables, project settings, and network reachability. Evaluate gap detection
rules from [`shared/knowledge-base/gap-detection-rules.md`](../../shared/knowledge-base/gap-detection-rules.md),
generate a blueprint using
[`shared/templates/gitlab-ci-blueprint.md`](../../shared/templates/gitlab-ci-blueprint.md)
with `.gitlab-ci.yml` job snippets, assign confidence scores, and present the
result for review before calling `/tas-integrator:export-blueprint`.

---

## Invocation

```
/tas-integrator:scan-gitlab
```

---

## Guardrails

Operate in **read-only** mode. MUST NOT modify the target GitLab instance in
any way.

| Constraint | Enforcement |
|------------|-------------|
| HTTP methods | `GET` only — no `POST`, `PUT`, `DELETE`, or `PATCH` requests to the GitLab API |
| Access token | Use solely for API authentication — never store, log, or write to files |
| GitLab configuration | Never modify — no pipeline edits, variable creation, or settings changes |
| File system | Only write the final blueprint file (when `save` or `both` output mode is used) |
| Network | Only connect to the GitLab API URL and TAS endpoint URLs for health checks |

MUST NOT attempt to read CI/CD variable values — the GitLab API does not
expose values to `read_api` scope tokens, and attempting to do so would violate
the read-only guardrail. Read only variable metadata (name, type, scope).

If any step would require a non-`GET` request to GitLab, skip that check and
record the gap as `skip` with a note explaining that write access is not
permitted.

---

## Inputs

Collect GitLab connection details and optional TAS endpoint overrides from the user.

### Required

| Parameter | Type | Description |
|-----------|------|-------------|
| `gitlab_url` | string | Set GitLab instance base URL (e.g. `https://gitlab.example.com`) |

### Optional

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `gitlab_token` | string | — | Provide personal access token or project/group token with `read_api` scope |
| `project_id` | string | — | Set GitLab project ID or URL-encoded path (e.g. `group/project`) to scan a single project |
| `group_id` | string | — | Set GitLab group ID to scan all projects in the group |
| `namespace` | string | — | Set Kubernetes/OpenShift namespace where TAS is deployed |
| `rekor_url` | string | auto-detect | Override Rekor endpoint URL |
| `fulcio_url` | string | auto-detect | Override Fulcio endpoint URL |
| `tuf_url` | string | auto-detect | Override TUF endpoint URL |
| `tsa_url` | string | auto-detect | Override TSA endpoint URL |
| `oidc_issuer` | string | auto-detect | Override OIDC issuer URL |
| `oidc_client_id` | string | auto-detect | Override OIDC client ID |
| `output` | string | `display` | Set output mode: `display`, `save`, or `both` |
| `format` | string | `markdown` | Set output format: `markdown` or `yaml` |
| `output_path` | string | auto-generated | Set file path for `save` and `both` modes |

### Authentication

When `gitlab_token` is provided, send it as a private token header on all
GitLab API requests:

```
PRIVATE-TOKEN: <gitlab_token>
```

If no token is provided, try unauthenticated access. On a `401` or `403`
response, prompt the user for a token and retry.

### Scope

- When `project_id` is provided, scan only that project.
- When `group_id` is provided, list all projects in the group and scan each.
- When neither is provided, prompt the user to specify a `project_id` or `group_id`.

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
| `COSIGN_REKOR_URL` | Detect Rekor URL via variable |
| `SIGSTORE_ID_TOKEN` | Detect Sigstore OIDC token variable |
| `id_tokens:` | Detect GitLab native OIDC token |

4. Store the total number of projects scanned, which patterns matched in
   which projects, whether signing/verification/attestation steps exist,
   and whether `id_tokens:` is used for OIDC.

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

#### 5c — From Kubernetes / OpenShift (if `namespace` provided)

If `namespace` is provided and `kubectl` is available, extract endpoints from
individual component CRD status fields:

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

Run all 24 rules from [shared/knowledge-base/gap-detection-rules.md](../../shared/knowledge-base/gap-detection-rules.md)
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
[shared/knowledge-base/gap-detection-rules.md](../../shared/knowledge-base/gap-detection-rules.md):

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
| `agent_version` | Read from [.claude-plugin/plugin.json](../../.claude-plugin/plugin.json) |
| `overall_confidence` | Step 7 |
| `overall_details` | Step 7 |
| `detection_confidence` | Step 7 |
| `detection_details` | Step 7 |
| `compatibility_confidence` | Step 7 |
| `compatibility_details` | Step 7 |
| `executive_summary` | Generated summary of scan findings |

#### 8b — Platform Data

Fill placeholders for [shared/templates/gitlab-ci-blueprint.md](../../shared/templates/gitlab-ci-blueprint.md):

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
[shared/knowledge-base/cosign-signing-patterns.md](../../shared/knowledge-base/cosign-signing-patterns.md) and
[shared/knowledge-base/oidc-setup.md](../../shared/knowledge-base/oidc-setup.md) (GitLab CI section).

Prefer GitLab's native `id_tokens` keyword for OIDC token acquisition — unlike
Jenkins, no external Keycloak token fetch is needed.

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
    FULCIO_URL: ${TAS_FULCIO_URL}
    REKOR_URL: ${TAS_REKOR_URL}
    OIDC_ISSUER: ${TAS_OIDC_ISSUER}
  script:
    - export ROOT_CHECKSUM=$(curl -s "${TUF_URL}/1.root.json" | sha256sum | awk '{print $1}')
    - cosign initialize
        --mirror="${TUF_URL}"
        --root="${TUF_URL}/1.root.json"
        --root-checksum="${ROOT_CHECKSUM}"
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

Substitute detected endpoint URLs for variable references when known.
Keep variable references when endpoints are not detected so the user can
configure them manually.

#### 8c — Gaps Data

Include the evaluated gap results from Step 6 as the `gaps` array.

#### 8d — Endpoints Data

Include the discovered endpoints from Step 5 as the `endpoints` object.

### Step 9 — Present for Review

Display a summary to the user for review before exporting the blueprint:

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

Prompt the user:

> "Review the scan results above. Would you like to proceed with blueprint
> generation, adjust any findings, or re-scan with different parameters?"

Wait for confirmation before proceeding to Step 10.

### Step 10 — Export Blueprint

Call `export-blueprint` with the assembled blueprint data from Step 8 and the
user's output parameters:

```
/tas-integrator:export-blueprint --output={{output}} --format={{format}}

Blueprint data:
- header: (assembled in Step 8a)
- platform: (assembled in Step 8b)
- gaps: (assembled in Step 8c)
- endpoints: (assembled in Step 8d)
```

Let `export-blueprint` handle template rendering, gap assessment summary,
validation command summary, metadata block, and output formatting.

---

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

## Knowledge Base References

Read these knowledge-base files during scanning:

| File | Read to |
|------|---------|
| [`shared/knowledge-base/gap-detection-rules.md`](../../shared/knowledge-base/gap-detection-rules.md) | Evaluate all 24 gap checks across 6 categories |
| [`shared/knowledge-base/cosign-signing-patterns.md`](../../shared/knowledge-base/cosign-signing-patterns.md) | Generate `.gitlab-ci.yml` snippets with correct `cosign` CLI flags |
| [`shared/knowledge-base/tas-endpoint-config.md`](../../shared/knowledge-base/tas-endpoint-config.md) | Map endpoint URLs, run health checks, and set CI/CD variables |
| [`shared/knowledge-base/oidc-setup.md`](../../shared/knowledge-base/oidc-setup.md) | Configure OIDC issuer, GitLab native `id_tokens`, and token injection |
| [`shared/knowledge-base/deployment-patterns.md`](../../shared/knowledge-base/deployment-patterns.md) | Detect OpenShift operator and RHEL Ansible deployment indicators |

---

## Error Handling

| Condition | Action |
|-----------|--------|
| GitLab URL unreachable | Report connection error and stop |
| Authentication required but token not provided | Prompt user for `gitlab_token` with `read_api` scope, then retry |
| Authentication failed (401/403) | Report invalid or insufficient token scope and stop |
| Token lacks `read_api` scope | Report required scope and stop |
| `.gitlab-ci.yml` not found | Record gap (no pipeline configured), continue |
| Included pipeline file not readable | Skip that include, log gap, continue scanning root config |
| Cross-project `include:` detected | Skip with note (read-only, no cross-project access), log gap, continue |
| CI/CD variables not accessible | Skip variable scan, log gap, continue |
| Runners not accessible | Skip runner scan, log gap, continue |
| TAS endpoints not detected | Insert `{{placeholder}}` markers in blueprint, warn user |
| `kubectl` not available for namespace scan | Skip operator detection, log gap, continue with other methods |
| Health check timeout (>10s) | Mark endpoint as unreachable, log gap, continue |
| No pipeline jobs found | Record gap (no signing steps found), continue |
| Group contains >100 projects | Scan first 100, warn user, suggest narrowing `project_id` scope |

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

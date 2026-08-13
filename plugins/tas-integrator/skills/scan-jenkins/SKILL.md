---
name: scan-jenkins
description: |
  Scan a Jenkins environment for TAS integration readiness and generate an integration blueprint.
---

# scan-jenkins

Scan a Jenkins environment for TAS integration readiness. Connect to the
Jenkins API (read-only), inspect installed plugins, pipeline configurations,
credential stores, and network reachability. Evaluate gap detection rules from
[`shared/knowledge-base/gap-detection-rules.md`](../../shared/knowledge-base/gap-detection-rules.md),
generate a blueprint using
[`shared/templates/jenkins-blueprint.md`](../../shared/templates/jenkins-blueprint.md)
with Jenkinsfile snippets, assign confidence scores, and present the result
for review before calling `/tas-integrator:export-blueprint`.

---

## Invocation

```
/tas-integrator:scan-jenkins
```

---

## Guardrails

Operate in **read-only** mode. MUST NOT modify the target Jenkins instance in
any way.

| Constraint | Enforcement |
|------------|-------------|
| HTTP methods | `GET` only — no `POST`, `PUT`, `DELETE`, or `PATCH` requests to the Jenkins API |
| Credentials | Use solely for API authentication — never store, log, or write to files |
| Jenkins configuration | Never modify — no job creation, plugin installation, or settings changes |
| File system | Only write the final blueprint file (when `save` or `both` output mode is used) |
| Network | Only connect to the Jenkins API URL and TAS endpoint URLs for health checks |

MUST NOT attempt to read credential values — the Jenkins API does not expose
them via `GET`, and attempting to do so would violate the read-only guardrail.
Read only credential metadata (ID, type, description).

If any step would require a non-`GET` request to Jenkins, skip that check and
record the gap as `skip` with a note explaining that write access is not
permitted.

---

## Inputs

Collect Jenkins connection details and optional TAS endpoint overrides.

### Required

| Parameter | Type | Description |
|-----------|------|-------------|
| `jenkins_url` | string | Set Jenkins server base URL (e.g. `https://jenkins.example.com`) |

### Optional

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `jenkins_user` | string | — | Set username for Jenkins API authentication |
| `jenkins_token` | string | — | Set API token or password for authentication |
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

When `jenkins_user` and `jenkins_token` are provided, send HTTP Basic
authentication on all Jenkins API requests:

```
Authorization: Basic base64(jenkins_user:jenkins_token)
```

If credentials are not provided, try unauthenticated access. On a `403` or
`401` response, prompt the user for credentials and retry.

---

## Processing Steps

### Step 1 — Connect to Jenkins

1. Send `GET {{jenkins_url}}/api/json` to verify connectivity.
2. If the request fails, report the error and stop.
3. Extract Jenkins version from the `X-Jenkins` response header.
4. Extract the Java version from `GET {{jenkins_url}}/systemInfo` (requires
   authentication — if unavailable, record as unknown).
5. Store `jenkins_version` (e.g. `2.426.3`) and `java_version` (e.g. `17.0.9`).

### Step 2 — Scan Installed Plugins

1. Send `GET {{jenkins_url}}/pluginManager/api/json?depth=2` to list all
   installed plugins.
2. Extract each plugin's `shortName`, `version`, and `active` status.
3. Check for TAS-relevant plugins:

| Plugin | Short Name | Use to |
|--------|------------|--------|
| Pipeline | `workflow-aggregator` | Run declarative/scripted pipelines |
| Credentials | `credentials` | Store credentials |
| Credentials Binding | `credentials-binding` | Inject credentials into build steps |
| Docker Pipeline | `docker-workflow` | Build and push Docker images |
| Pipeline Utility Steps | `pipeline-utility-steps` | Read/write files in pipelines |
| HTTP Request | `http_request` | Make HTTP calls from pipelines |
| Git | `git` | Check out SCM repositories |

4. Classify each plugin: mark `installed` + `active` as available, mark
   `installed` but inactive as disabled (gap), mark absent as missing (gap).

### Step 3 — Scan Pipeline Configurations

1. Send `GET {{jenkins_url}}/api/json?tree=jobs[name,url,color]` to list all
   jobs.
2. For each Pipeline or MultiBranch Pipeline job, retrieve the pipeline
   definition:
   - Scripted/Declarative: `GET {{job_url}}/config.xml` — extract the
     `<script>` or `<definition>` element.
   - MultiBranch: `GET {{job_url}}/config.xml` — extract the SCM source
     for `Jenkinsfile` location.
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
| `COSIGN_REKOR_URL` | Detect Rekor URL via env var |

4. Store the total pipeline jobs scanned, which patterns matched in which
   jobs, and whether signing/verification/attestation steps exist.

### Step 4 — Scan Credential Store

1. Send `GET {{jenkins_url}}/credentials/store/system/domain/_/api/json?depth=2`
   to list system-scoped credentials.
2. For each credential, extract:
   - `id` — credential identifier
   - `typeName` — credential type (e.g. `Secret text`, `Username with password`,
     `Certificate`, `SSH key`)
   - `description` — user-provided description
3. Check for TAS-related credentials by matching `id` or `description` against:

| Pattern | Indicates |
|---------|-----------|
| `cosign`, `sigstore` | Flag as Cosign-related credential |
| `rekor`, `fulcio`, `tsa`, `tuf` | Flag as TAS endpoint credential |
| `oidc`, `keycloak`, `sso` | Flag as OIDC-related credential |
| `registry`, `docker`, `quay` | Flag as container registry credential |

4. Store which credential types are present and which are missing.

**Note:** Read only credential metadata (ID, type, description) — never read
values (see Guardrails).

### Step 5 — Detect TAS Endpoints

Discover TAS endpoint URLs. Use explicit overrides from the input parameters
if provided. Otherwise, attempt auto-detection in this order:

#### 5a — From Jenkins Environment Variables

Run `GET {{jenkins_url}}/env` or inspect pipeline environment blocks for
variables matching:

| Variable | Set |
|----------|-----|
| `TAS_REKOR_URL` or `COSIGN_REKOR_URL` | Set `rekor_url` |
| `TAS_FULCIO_URL` | Set `fulcio_url` |
| `TAS_TUF_URL` | Set `tuf_url` |
| `TAS_TSA_URL` | Set `tsa_url` |
| `TAS_OIDC_ISSUER` | Set `oidc_issuer` |
| `TAS_OIDC_CLIENT_ID` | Set `oidc_client_id` |

#### 5b — From Kubernetes / OpenShift (if `namespace` provided)

If `namespace` is provided and `kubectl` is available, extract endpoints from
the Securesign CR status fields:

```bash
REKOR_URL=$(kubectl get securesign -n {{namespace}} \
  -o jsonpath='{.items[0].status.rekor.url}')
FULCIO_URL=$(kubectl get securesign -n {{namespace}} \
  -o jsonpath='{.items[0].status.fulcio.url}')
TUF_URL=$(kubectl get securesign -n {{namespace}} \
  -o jsonpath='{.items[0].status.tuf.url}')
TSA_URL=$(kubectl get securesign -n {{namespace}} \
  -o jsonpath='{.items[0].status.tsa.url}')
```

#### 5c — From RHEL Configuration

If the Jenkins controller runs on RHEL, check for the `/etc/rhtas/` directory
to detect an Ansible-deployed TAS instance.

#### 5d — Endpoint Health Checks

Run a health check for every discovered endpoint:

| Component | Health Check | Expected |
|-----------|-------------|----------|
| Fulcio | `GET {{fulcio_url}}/healthz` | HTTP 200 |
| Rekor | `GET {{rekor_url}}/api/v1/log` | HTTP 200 |
| TSA | `GET {{tsa_url}}/api/v1/timestamp/certchain` | HTTP 200 |
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
| `OIDC` | Use Step 3 pipeline patterns + Step 5 environment variables |
| `SIGN` | Use Step 3 pipeline patterns |
| `VERIFY` | Use Step 3 pipeline patterns |
| `POLICY` | Use Step 5b Kubernetes CRD check (if available) |
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
| `cicd_platform` | `jenkins` |
| `agent_version` | Version from [.claude-plugin/plugin.json](../../.claude-plugin/plugin.json) |
| `overall_confidence` | Step 7 |
| `overall_details` | Step 7 |
| `detection_confidence` | Step 7 |
| `detection_details` | Step 7 |
| `compatibility_confidence` | Step 7 |
| `compatibility_details` | Step 7 |
| `executive_summary` | Generated summary of scan findings |

#### 8b — Platform Data

Fill placeholders for [shared/templates/jenkins-blueprint.md](../../shared/templates/jenkins-blueprint.md):

| Placeholder | Source |
|-------------|--------|
| `jenkins_version_status` | Set from Step 1 — `OK` if detected, `Unknown` otherwise |
| `jenkins_version_details` | Set from Step 1 — version string |
| `java_version_status` | Set from Step 1 — `OK` if Java 11+, `Warning` if older |
| `java_version_details` | Set from Step 1 — version string |
| `network_status` | Set from Step 5d — `OK` if all endpoints reachable |
| `network_details` | Set from Step 5d — summarize reachable/unreachable endpoints |
| `tas_server_status` | Set from Step 5 — `OK` if at least Fulcio + Rekor detected |
| `tas_server_details` | Set from Step 5 — include deployment method and endpoints |
| `oidc_status` | Set from Step 6 OIDC rules — `OK` if OIDC-001 and OIDC-002 pass |
| `oidc_details` | Set from Step 6 — include OIDC issuer and client ID if detected |
| `plugin_name` | Set from Step 2 — add one row per required plugin |
| `plugin_version` | Set from Step 2 — use installed version or `Not installed` |
| `plugin_purpose` | Set from Step 2 — use plugin purpose from the table in Step 2 |
| `plugin_installation_steps` | Generate `jenkins-cli install-plugin` commands for missing plugins |

##### Credential, Pipeline & Validation Placeholders

| Placeholder | Source |
|-------------|--------|
| `credential_id` | Set from Step 4 — add one row per required credential |
| `credential_type` | Set from Step 4 — use credential type |
| `credential_scope` | Set to `Global` (default) |
| `credential_description` | Set from Step 4 — describe credential purpose |
| `credential_configuration_steps` | Generate credential setup instructions |
| `signing_stage_snippet` | Generate Jenkinsfile signing stage using detected endpoints |
| `verification_stage_snippet` | Generate Jenkinsfile verification stage |
| `attestation_stage_snippet` | Generate Jenkinsfile attestation stage |
| `full_pipeline_example` | Generate complete Jenkinsfile combining all stages |
| `validation_command` | Add one row per validation command |
| `validation_purpose` | Describe command purpose |
| `validation_expected` | Describe expected output |
| `checklist_item` | Add one row per post-integration checklist item |

#### Jenkinsfile Snippet Generation

Generate Groovy pipeline snippets using patterns from
[shared/knowledge-base/cosign-signing-patterns.md](../../shared/knowledge-base/cosign-signing-patterns.md) and
[shared/knowledge-base/oidc-setup.md](../../shared/knowledge-base/oidc-setup.md) (Jenkins section).

Generate the signing stage — run `cosign initialize` then `cosign sign`:

```groovy
stage('Sign Image') {
    steps {
        script {
            // Confidential client: use grant_type=client_credentials with OIDC_CLIENT_SECRET
            // Public client: use grant_type=password with OIDC_USER/OIDC_PASSWORD
            def IDENTITY_TOKEN = sh(
                script: """
                    curl -s -X POST \
                      "\${TAS_OIDC_ISSUER}/protocol/openid-connect/token" \
                      -d "grant_type=client_credentials" \
                      -d "client_id=\${OIDC_CLIENT_ID}" \
                      -d "client_secret=\${OIDC_CLIENT_SECRET}" \
                      | jq -r '.access_token'
                """,
                returnStdout: true
            ).trim()

            sh """
                cosign initialize \
                  --mirror=\${TUF_URL} \
                  --root=\${TUF_URL}/root.json

                cosign sign \
                  --fulcio-url=\${FULCIO_URL} \
                  --rekor-url=\${REKOR_URL} \
                  --oidc-issuer=\${OIDC_ISSUER} \
                  --oidc-client-id=\${OIDC_CLIENT_ID} \
                  --identity-token=${IDENTITY_TOKEN} \
                  --yes \
                  \${IMAGE_REFERENCE}
            """
        }
    }
}
```

Generate the verification stage — run `cosign verify` with certificate identity:

```groovy
stage('Verify Image') {
    steps {
        sh """
            cosign verify \
              --rekor-url=\${REKOR_URL} \
              --certificate-identity=\${EXPECTED_IDENTITY} \
              --certificate-oidc-issuer=\${OIDC_ISSUER} \
              \${IMAGE_REFERENCE}
        """
    }
}
```

Generate the attestation stage — run `cosign attest` with SBOM predicates:

```groovy
stage('Attest Image') {
    steps {
        script {
            def IDENTITY_TOKEN = sh(
                script: """
                    curl -s -X POST \
                      "\${TAS_OIDC_ISSUER}/protocol/openid-connect/token" \
                      -d "grant_type=client_credentials" \
                      -d "client_id=\${OIDC_CLIENT_ID}" \
                      -d "client_secret=\${OIDC_CLIENT_SECRET}" \
                      | jq -r '.access_token'
                """,
                returnStdout: true
            ).trim()

            sh """
                cosign attest \
                  --fulcio-url=\${FULCIO_URL} \
                  --rekor-url=\${REKOR_URL} \
                  --oidc-issuer=\${OIDC_ISSUER} \
                  --oidc-client-id=\${OIDC_CLIENT_ID} \
                  --identity-token=${IDENTITY_TOKEN} \
                  --predicate=\${SBOM_FILE} \
                  --type=spdxjson \
                  --yes \
                  \${IMAGE_REFERENCE}
            """
        }
    }
}
```

Substitute detected endpoint URLs for environment variable references when
known. Keep variable references when endpoints are not detected so the user
can configure them manually.

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
| Jenkins URL | {{jenkins_url}} |
| Jenkins Version | {{jenkins_version}} |
| Java Version | {{java_version}} |
| Plugins Scanned | {{total_plugins}} |
| Pipelines Scanned | {{total_pipelines}} |
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

## Jenkins API Reference

Send `GET` requests with the `/api/json` suffix for JSON responses.

| Endpoint | Use to |
|----------|--------|
| `GET /api/json` | Retrieve server info and top-level job list |
| `GET /pluginManager/api/json?depth=2` | List installed plugins with details |
| `GET /credentials/store/system/domain/_/api/json?depth=2` | List system credential metadata |
| `GET /job/{{job_name}}/api/json` | Retrieve job details |
| `GET /job/{{job_name}}/config.xml` | Retrieve job configuration (pipeline script) |
| `GET /systemInfo` | Retrieve system properties including Java version |
| `GET /queue/api/json` | Verify API access via build queue |

Filter fields with the `tree` query parameter:

```
GET /api/json?tree=jobs[name,url,color]
```

---

## Knowledge Base References

Read these knowledge-base files during scanning:

| File | Read to |
|------|---------|
| [`shared/knowledge-base/gap-detection-rules.md`](../../shared/knowledge-base/gap-detection-rules.md) | Evaluate all 24 gap checks across 6 categories |
| [`shared/knowledge-base/cosign-signing-patterns.md`](../../shared/knowledge-base/cosign-signing-patterns.md) | Generate Jenkinsfile snippets with correct `cosign` CLI flags |
| [`shared/knowledge-base/tas-endpoint-config.md`](../../shared/knowledge-base/tas-endpoint-config.md) | Map endpoint URLs, run health checks, and set CI/CD variables |
| [`shared/knowledge-base/oidc-setup.md`](../../shared/knowledge-base/oidc-setup.md) | Configure OIDC issuer, Keycloak integration, and Jenkins token injection |
| [`shared/knowledge-base/deployment-patterns.md`](../../shared/knowledge-base/deployment-patterns.md) | Detect OpenShift operator and RHEL Ansible deployment indicators |

---

## Error Handling

| Condition | Action |
|-----------|--------|
| Jenkins URL unreachable | Report connection error and stop |
| Authentication required but credentials not provided | Prompt user for `jenkins_user` and `jenkins_token`, then retry |
| Authentication failed (401/403) | Report invalid credentials and stop |
| Plugin API not accessible | Skip plugin scan, log gap, continue with other steps |
| Pipeline `config.xml` not readable | Skip that pipeline, log gap, continue scanning others |
| Credential store not accessible | Skip credential scan, log gap, continue |
| TAS endpoints not detected | Insert `{{placeholder}}` markers in blueprint, warn user |
| `kubectl` not available for namespace scan | Skip operator detection, log gap, continue with other methods |
| Health check timeout (>10s) | Mark endpoint as unreachable, log gap, continue |
| No pipeline jobs found | Record gap (no signing steps found), continue |

---

## Examples

### Basic Scan (Display Only)

Run a scan and display results in the conversation:

```
/tas-integrator:scan-jenkins

Jenkins URL: https://jenkins.example.com
Username: admin
Token: 11a2b3c4d5e6f7
```

### Scan with TAS Namespace

Run a scan and auto-detect endpoints from the Securesign CR in the namespace:

```
/tas-integrator:scan-jenkins

Jenkins URL: https://jenkins.example.com
Username: admin
Token: 11a2b3c4d5e6f7
Namespace: trusted-artifact-signer
```

### Scan with Explicit Endpoints and YAML Save

Override endpoint URLs and write the blueprint as YAML:

```
/tas-integrator:scan-jenkins --output=save --format=yaml

Jenkins URL: https://jenkins.example.com
Username: admin
Token: 11a2b3c4d5e6f7
Rekor URL: https://rekor.tas.example.com
Fulcio URL: https://fulcio.tas.example.com
TUF URL: https://tuf.tas.example.com
```

### Scan with Display and Save

Display the blueprint and save it to a custom output path:

```
/tas-integrator:scan-jenkins --output=both --output_path=./reports/jenkins-scan.md

Jenkins URL: https://jenkins.example.com
Username: admin
Token: 11a2b3c4d5e6f7
Namespace: trusted-artifact-signer
```

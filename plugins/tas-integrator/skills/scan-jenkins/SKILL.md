---
name: scan-jenkins
description: |
  Scan a Jenkins environment for TAS integration readiness and generate an integration blueprint.
---

# scan-jenkins

Scans a Jenkins environment for TAS integration readiness. Connects to the
Jenkins API (read-only), inspects installed plugins, pipeline configurations,
credential stores, and network reachability. Evaluates gap detection rules,
generates a blueprint using the Jenkins template with Jenkinsfile snippets,
assigns confidence scores, and presents the result for review before export.

---

## Invocation

```
/tas-integrator:scan-jenkins
```

---

## Guardrails

This skill operates in **read-only** mode. It MUST NOT modify the target Jenkins
instance in any way.

| Constraint | Enforcement |
|------------|-------------|
| HTTP methods | `GET` only — no `POST`, `PUT`, `DELETE`, or `PATCH` requests to the Jenkins API |
| Credentials | Used solely for API authentication — never stored, logged, or written to files |
| Jenkins configuration | Never modified — no job creation, plugin installation, or settings changes |
| File system | Only writes the final blueprint file (when `save` or `both` output mode is used) |
| Network | Only connects to the Jenkins API URL and TAS endpoint URLs for health checks |

The skill MUST NOT attempt to read credential values — the Jenkins API does not
expose them via `GET`, and attempting to do so would violate the read-only
guardrail. Only credential metadata (ID, type, description) is read.

If any step would require a non-`GET` request to Jenkins, skip that check and
record the gap as `skip` with a note explaining that write access is not
permitted.

---

## Inputs

The caller provides Jenkins connection details and optional TAS endpoint
overrides.

### Required

| Parameter | Type | Description |
|-----------|------|-------------|
| `jenkins_url` | string | Jenkins server base URL (e.g. `https://jenkins.example.com`) |

### Optional

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `jenkins_user` | string | — | Username for Jenkins API authentication |
| `jenkins_token` | string | — | API token or password for authentication |
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

If `jenkins_user` and `jenkins_token` are provided, use HTTP Basic
authentication for all Jenkins API requests:

```
Authorization: Basic base64(jenkins_user:jenkins_token)
```

If credentials are not provided, attempt unauthenticated access. If a `403` or
`401` response is received, prompt the user for credentials before retrying.

---

## Processing Steps

### Step 1 — Connect to Jenkins

1. Send `GET {{jenkins_url}}/api/json` to verify connectivity.
2. If the request fails, report the error and stop.
3. Extract Jenkins version from the `X-Jenkins` response header.
4. Extract the Java version from `GET {{jenkins_url}}/systemInfo` (requires
   authentication — if unavailable, record as unknown).
5. Record:
   - `jenkins_version` — e.g. `2.426.3`
   - `java_version` — e.g. `17.0.9`

### Step 2 — Scan Installed Plugins

1. Send `GET {{jenkins_url}}/pluginManager/api/json?depth=2` to list all
   installed plugins.
2. Extract each plugin's `shortName`, `version`, and `active` status.
3. Check for TAS-relevant plugins:

| Plugin | Short Name | Purpose |
|--------|------------|---------|
| Pipeline | `workflow-aggregator` | Declarative/Scripted pipeline support |
| Credentials | `credentials` | Credential storage |
| Credentials Binding | `credentials-binding` | Inject credentials into build steps |
| Docker Pipeline | `docker-workflow` | Docker build and push steps |
| Pipeline Utility Steps | `pipeline-utility-steps` | File read/write in pipelines |
| HTTP Request | `http_request` | HTTP calls from pipelines |
| Git | `git` | SCM checkout |

4. Record the status of each plugin:
   - `installed` and `active` — available
   - `installed` but not `active` — disabled (gap)
   - not installed — missing (gap)

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
| `cosign sign` | Signing step present |
| `cosign verify` | Verification step present |
| `cosign attest` | Attestation step present |
| `cosign initialize` | TUF initialization present |
| `--fulcio-url` | Fulcio endpoint configured |
| `--rekor-url` | Rekor endpoint configured |
| `--oidc-issuer` | OIDC issuer configured |
| `--identity-token` | Identity token injection |
| `COSIGN_REKOR_URL` | Rekor URL via environment variable |

4. Record:
   - Total number of pipeline jobs scanned
   - Which patterns were found and in which jobs
   - Whether any signing, verification, or attestation steps exist

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
| `cosign`, `sigstore` | Cosign-related credential |
| `rekor`, `fulcio`, `tsa`, `tuf` | TAS endpoint credential |
| `oidc`, `keycloak`, `sso` | OIDC-related credential |
| `registry`, `docker`, `quay` | Container registry credential |

4. Record which credential types are present and which are missing.

**Note:** The skill reads only credential metadata (ID, type, description), not
values (see Guardrails).

### Step 5 — Detect TAS Endpoints

Attempt to discover TAS endpoint URLs. Use explicit overrides from the input
parameters if provided. Otherwise, try auto-detection in this order:

#### 5a — From Jenkins Environment Variables

Send `GET {{jenkins_url}}/env` or inspect pipeline environment blocks for
variables matching:

| Variable | Maps To |
|----------|---------|
| `TAS_REKOR_URL` or `COSIGN_REKOR_URL` | `rekor_url` |
| `TAS_FULCIO_URL` | `fulcio_url` |
| `TAS_TUF_URL` | `tuf_url` |
| `TAS_TSA_URL` | `tsa_url` |
| `TAS_OIDC_ISSUER` | `oidc_issuer` |
| `TAS_OIDC_CLIENT_ID` | `oidc_client_id` |

#### 5b — From Kubernetes / OpenShift (if `namespace` provided)

If a `namespace` is provided and `kubectl` is available, discover endpoints
from the Securesign CR status fields:

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

If the Jenkins controller runs on RHEL, check for `/etc/rhtas/` directory
presence as an indicator of an Ansible-deployed TAS instance.

#### 5d — Endpoint Health Checks

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
| `OIDC` | Step 3 pipeline patterns + Step 5 environment variables |
| `SIGN` | Step 3 pipeline patterns |
| `VERIFY` | Step 3 pipeline patterns |
| `POLICY` | Step 5b Kubernetes CRD check (if available) |
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
| `cicd_platform` | `jenkins` |
| `agent_version` | Version from `.claude-plugin/plugin.json` |
| `overall_confidence` | Step 7 |
| `overall_details` | Step 7 |
| `detection_confidence` | Step 7 |
| `detection_details` | Step 7 |
| `compatibility_confidence` | Step 7 |
| `compatibility_details` | Step 7 |
| `executive_summary` | Generated summary of scan findings |

#### 8b — Platform Data

Populate placeholders for `shared/templates/jenkins-blueprint.md`:

| Placeholder | Source |
|-------------|--------|
| `jenkins_version_status` | Step 1 — `OK` if version detected, `Unknown` otherwise |
| `jenkins_version_details` | Step 1 — version string |
| `java_version_status` | Step 1 — `OK` if Java 11+, `Warning` if older |
| `java_version_details` | Step 1 — version string |
| `network_status` | Step 5d — `OK` if all endpoints reachable |
| `network_details` | Step 5d — summary of reachable/unreachable endpoints |
| `tas_server_status` | Step 5 — `OK` if at least Fulcio + Rekor detected |
| `tas_server_details` | Step 5 — deployment method and endpoints |
| `oidc_status` | Step 6 OIDC rules — `OK` if OIDC-001 and OIDC-002 pass |
| `oidc_details` | Step 6 — OIDC issuer and client ID if detected |
| `plugin_name` | Step 2 — one row per required plugin |
| `plugin_version` | Step 2 — installed version or `Not installed` |
| `plugin_purpose` | Step 2 — plugin purpose from the table in Step 2 |
| `plugin_installation_steps` | Generated installation commands for missing plugins |
| `credential_id` | Step 4 — one row per required credential |
| `credential_type` | Step 4 — credential type |
| `credential_scope` | `Global` (default) |
| `credential_description` | Step 4 — credential purpose |
| `credential_configuration_steps` | Generated credential setup instructions |
| `signing_stage_snippet` | Jenkinsfile signing stage using detected endpoints |
| `verification_stage_snippet` | Jenkinsfile verification stage |
| `attestation_stage_snippet` | Jenkinsfile attestation stage |
| `full_pipeline_example` | Complete Jenkinsfile combining all stages |
| `validation_command` | One row per validation command |
| `validation_purpose` | Command purpose |
| `validation_expected` | Expected output |
| `checklist_item` | One row per post-integration checklist item |

#### Jenkinsfile Snippet Generation

Use patterns from `shared/knowledge-base/cosign-signing-patterns.md` and
`shared/knowledge-base/oidc-setup.md` (Jenkins section) to generate Groovy
pipeline snippets.

**Signing stage:**

```groovy
stage('Sign Image') {
    steps {
        script {
            // Production: client_credentials grant (requires confidential client
            // in Keycloak — set publicClient: false, serviceAccountsEnabled: true)
            // Dev/test: replace with grant_type=password using OIDC_USER/OIDC_PASSWORD
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

**Verification stage:**

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

**Attestation stage:**

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

Substitute detected endpoint URLs for the environment variable references when
endpoints are known. When endpoints are not detected, keep the environment
variable references so the user can configure them.

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

## Jenkins API Reference

All API calls use `GET` requests with the `/api/json` suffix for JSON responses.

| Endpoint | Purpose |
|----------|---------|
| `GET /api/json` | Server info and top-level job list |
| `GET /pluginManager/api/json?depth=2` | Installed plugins with details |
| `GET /credentials/store/system/domain/_/api/json?depth=2` | System credential metadata |
| `GET /job/{{job_name}}/api/json` | Job details |
| `GET /job/{{job_name}}/config.xml` | Job configuration (pipeline script) |
| `GET /systemInfo` | System properties including Java version |
| `GET /queue/api/json` | Build queue (used to verify API access) |

All endpoints support the `tree` query parameter for field filtering:

```
GET /api/json?tree=jobs[name,url,color]
```

---

## Knowledge Base References

This skill draws from the following knowledge base files during scanning:

| File | Usage |
|------|-------|
| `shared/knowledge-base/gap-detection-rules.md` | Rule definitions for all 24 gap checks across 6 categories |
| `shared/knowledge-base/cosign-signing-patterns.md` | Cosign CLI flags and command patterns for Jenkinsfile snippet generation |
| `shared/knowledge-base/tas-endpoint-config.md` | Endpoint URL formats, health check commands, and CI/CD variable mapping |
| `shared/knowledge-base/oidc-setup.md` | OIDC issuer types, Keycloak integration, and Jenkins token injection patterns |
| `shared/knowledge-base/deployment-patterns.md` | OpenShift operator and RHEL Ansible deployment detection indicators |

---

## Error Handling

| Condition | Behaviour |
|-----------|-----------|
| Jenkins URL unreachable | Report connection error, stop |
| Authentication required but credentials not provided | Prompt user for credentials, retry |
| Authentication failed (401/403) | Report invalid credentials, stop |
| Plugin API not accessible | Record plugin scan as skipped, continue with other steps |
| Pipeline config.xml not readable | Skip that pipeline, continue scanning others |
| Credential store not accessible | Record credential scan as skipped, continue |
| TAS endpoints not detected | Use `{{placeholder}}` markers in blueprint, warn user |
| `kubectl` not available for namespace scan | Skip operator detection, continue with other methods |
| Health check timeout (>10s) | Record endpoint as unreachable, continue |
| No pipeline jobs found | Record as gap (no signing steps), continue |

---

## Examples

### Basic Scan (Display Only)

```
/tas-integrator:scan-jenkins

Jenkins URL: https://jenkins.example.com
Username: admin
Token: 11a2b3c4d5e6f7
```

### Scan with TAS Namespace

```
/tas-integrator:scan-jenkins

Jenkins URL: https://jenkins.example.com
Username: admin
Token: 11a2b3c4d5e6f7
Namespace: trusted-artifact-signer
```

### Scan with Explicit Endpoints and YAML Save

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

```
/tas-integrator:scan-jenkins --output=both --output_path=./reports/jenkins-scan.md

Jenkins URL: https://jenkins.example.com
Username: admin
Token: 11a2b3c4d5e6f7
Namespace: trusted-artifact-signer
```

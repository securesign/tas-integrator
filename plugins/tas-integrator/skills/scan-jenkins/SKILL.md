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
| `--use-signing-config=false` | Detect explicit URL mode (TUF disabled) |
| `COSIGN_REKOR_URL` | Detect Rekor URL via env var |

4. **Detect current signing-config mode** in existing pipelines:
   - If `cosign initialize` found AND no `--use-signing-config=false` → **Current mode: TUF**
   - If `--use-signing-config=false` OR explicit `--fulcio-url`/`--rekor-url` flags without `cosign initialize` → **Current mode: Explicit URLs**
   - If `cosign sign` found but neither pattern detected → **Current mode: Unknown** (legacy/non-standard)
   - If no `cosign` commands found → **Current mode: None** (no existing integration)

5. Store the total pipeline jobs scanned, which patterns matched in which
   jobs, whether signing/verification/attestation steps exist, and the **detected current mode**.

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
# Append /api/v1/timestamp if not already present (for older operator versions)
[[ -n "$TSA_URL" && "$TSA_URL" != */api/v1/timestamp ]] && TSA_URL="${TSA_URL}/api/v1/timestamp"
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
| TSA | `GET {{tsa_url}}/certchain` | HTTP 200 |
| TUF | `GET {{tuf_url}}/root.json` | HTTP 200 |

Store pass/fail for each endpoint check.

#### 5e — OIDC Provider Type and Client Detection

Classify the detected OIDC provider and, for Keycloak-based providers, probe for
client type.

**Provider Classification:**

Examine the `oidc_issuer` URL pattern to determine the provider type:

| Pattern | Provider Type | Notes |
|---------|--------------|-------|
| Contains `/realms/` or `/auth/realms/` | `keycloak` | Keycloak, RHBK, or Red Hat SSO |
| Contains `token.actions.githubusercontent.com` | `github-actions` | GitHub Actions native OIDC |
| Contains `gitlab.com` or ends with `.gitlab.io` | `gitlab-native` | GitLab native OIDC |
| Contains `googleapis.com` or `accounts.google.com` | `google` | Google OAuth |
| Contains `login.microsoftonline.com` or `sts.windows.net` | `microsoft` | Microsoft Entra ID |
| Contains `.amazonaws.com` | `aws-sts` | Amazon Security Token Service |
| Other | `generic` | Generic OIDC provider |

Record `oidc_provider_type` for use in Step 8b blueprint generation.

**Keycloak Client Type Detection:**

If `oidc_provider_type` is `keycloak`, probe the token endpoint to detect whether
the client is public or confidential:

```bash
PROBE_RESPONSE=$(curl -s -X POST \
  "{{oidc_issuer}}/protocol/openid-connect/token" \
  -d "grant_type=client_credentials" \
  -d "client_id={{oidc_client_id}}" \
  2>&1)
```

Classify the client type based on the error response:

| Response Pattern | Client Type |
|------------------|-------------|
| Error contains `"public client"` or `"service account"` | `public` |
| Error contains `"client secret"` or `"invalid credentials"` or `"unauthorized_client"` | `confidential` |
| HTTP 200 (token returned) | `confidential` |
| Unreachable or ambiguous | `unknown` (default to `public`) |

Record `oidc_client_type` as `public`, `confidential`, or `unknown`.

**Non-Keycloak Providers:**

For non-Keycloak providers, skip client type detection and set `oidc_client_type`
to `not-applicable`. The blueprint will include provider-specific guidance instead
of Keycloak-specific snippets.

### Step 6 — Evaluate Gap Detection Rules

Run all 25 rules from [shared/knowledge-base/gap-detection-rules.md](../../shared/knowledge-base/gap-detection-rules.md)
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
| `OIDC` | Use Step 3 pipeline patterns + Step 5 environment variables + Step 5e client type detection |
| `SIGN` | Use Step 3 pipeline patterns |
| `VERIFY` | Use Step 3 pipeline patterns |
| `POLICY` | Use Step 5b Kubernetes CRD check (if available) |
| `SUPPLY` | Use Step 3 pipeline patterns (SBOM tools, attestation commands) |

**OIDC-005 Evaluation:** Evaluate OIDC-005 using the `oidc_client_type` result from Step 5e:
- `pass` if client type is `public` or `confidential` (detected successfully)
- `fail` if client type is `unknown` (detection failed or was skipped)
- Include the detected client type in the `details` field

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
| `cosign_cli_status` | Set from Step 6 INFRA-006 — `OK` if passed, `Unknown` if skipped, `Missing` if failed |
| `cosign_cli_details` | Set from Step 6 INFRA-006 — version string if passed; `Cannot verify remotely — ensure cosign is installed on Jenkins agent nodes` if skipped; `cosign CLI not found — install via package manager, container image, or binary download` if failed |
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

**Provider-Specific Token Acquisition:**

Based on the `oidc_provider_type` detected in Step 5e, generate appropriate guidance:

**For `keycloak` providers:**

Generate Keycloak-specific snippets based on `oidc_client_type`:
- **If `confidential`:** Use `client_credentials` grant with `OIDC_CLIENT_SECRET`
- **If `public` or `unknown`:** Use `password` grant with `OIDC_USER`/`OIDC_PASSWORD`

**For non-Keycloak providers:**

Generate a guidance section instead of executable snippets. Include:
- Provider name and detected issuer URL
- Note that Jenkins lacks native OIDC for this provider
- Link to RHTAS Deployment Guide section for the specific provider
- Recommendation to use Keycloak/RHBK for Jenkins CI/CD automation

See "Non-Keycloak Provider Guidance" section below for templates.

---

**Mode Selection: TUF Mode vs Explicit URL Mode**

Choose which mode to generate based on existing configuration, TUF availability, and customer preference.

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

Include a recommendation section in the blueprint that explains the choice and alternatives:

```markdown
## 🎯 Signing-Config Mode: {{selected_mode}}

**Current Configuration:** {{current_mode_status}}
**Selected Mode:** {{selected_mode}} ({{selection_reason}})

### Mode Comparison

| Aspect | TUF Mode | Explicit URL Mode |
|--------|----------|-------------------|
| **Security** | ✅ Uses TUF for service discovery & root-of-trust | ⚠️ Manual URL configuration, no automatic root updates |
| **Maintenance** | ✅ Automatic service URL updates via TUF | ⚠️ Manual updates needed when URLs change |
| **Setup Complexity** | Requires `cosign initialize` once | Simpler - no initialization step |
| **URL Management** | Hidden in TUF metadata | Explicit in pipeline code |
| **RHTAS Compatibility** | ✅ Recommended for RHTAS 1.0+ | Compatible with all versions |
| **Transparency** | Service URLs abstracted | Service URLs visible in pipeline |

### When to Use TUF Mode (Recommended)

✅ **Use TUF Mode if:**
- TUF service is available and reachable
- You want automatic root-of-trust updates
- You prefer centralized service URL management
- You're following RHTAS deployment best practices
- **Current status:** {{tuf_recommendation_status}}

### When to Use Explicit URL Mode

✅ **Use Explicit URL Mode if:**
- TUF service is unavailable or unreachable from Jenkins
- You need full visibility of service URLs in pipeline code
- You're migrating from Sigstore Public Good to RHTAS
- You have compliance requirements for explicit service configuration
- **Current status:** {{explicit_recommendation_status}}

### Recommendation

{{mode_recommendation_text}}
```

**Placeholder substitutions:**

| Placeholder | Value |
|-------------|-------|
| `{{selected_mode}}` | `TUF Mode` or `Explicit URL Mode` |
| `{{current_mode_status}}` | `TUF Mode detected in 3 pipelines` / `Explicit URL Mode detected in 2 pipelines` / `No existing integration` / `Unknown configuration` |
| `{{selection_reason}}` | Why this mode was chosen per priority table |
| `{{tuf_recommendation_status}}` | `✅ TUF available at {{tuf_url}}` or `❌ TUF not detected` |
| `{{explicit_recommendation_status}}` | `✅ All service URLs detected` or `⚠️ Some URLs missing - will use placeholders` |
| `{{mode_recommendation_text}}` | Custom recommendation based on scan results |

**Example recommendations:**

*Scenario 1: TUF available, no existing integration (greenfield)*
```
We recommend **TUF Mode** for this greenfield deployment. TUF provides better security 
and simpler long-term maintenance. Your TUF service at {{tuf_url}} is reachable and 
healthy.

If you prefer explicit URLs for transparency, re-run with "use explicit URLs" in your request.
```

*Scenario 2: Existing pipelines use TUF mode*
```
Your existing pipelines already use **TUF Mode** (detected `cosign initialize` in 3 
pipelines). This blueprint preserves that configuration for consistency.

To migrate to Explicit URL Mode, re-run with "use explicit URLs" in your request.
```

*Scenario 3: TUF unavailable (forced explicit mode)*
```
**TUF Mode is recommended** but your TUF service is currently unreachable from Jenkins. 
This blueprint uses **Explicit URL Mode** as a fallback.

Once TUF connectivity is established, consider migrating to TUF Mode for better security 
and easier maintenance.
```

*Scenario 4: User explicitly requested explicit URLs*
```
Using **Explicit URL Mode** per your request. All service URLs will be explicitly 
configured in pipeline environment variables.

TUF Mode is available ({{tuf_url}}) if you prefer centralized service management in the future.
```

---

**Initialize TUF Stage (TUF Mode Only):**

Generate the TUF initialization stage that runs once before signing. This stage
extracts the TAS server CA certificate and initializes cosign with the TUF root,
enabling TUF mode for all subsequent `cosign` commands.

```groovy
stage('Initialize TUF') {
    steps {
        echo 'Initializing TUF for TAS...'
        sh '''
            # Remove any cached sigstore config
            rm -rf /var/jenkins_home/.sigstore || true

            # Extract TAS server CA certificate for TLS verification
            TAS_HOST=$(echo "${TAS_TUF_URL}" | sed 's|^https://||' | cut -d/ -f1)
            echo | openssl s_client -showcerts -connect "${TAS_HOST}:443" 2>/dev/null \
                | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > /tmp/tuf-ca.crt

            # Set CA cert for TUF initialization
            export SSL_CERT_FILE=/tmp/tuf-ca.crt
            export CURL_CA_BUNDLE=/tmp/tuf-ca.crt

            # Initialize TUF
            ROOT_CHECKSUM=$(curl -s "${TAS_TUF_URL}/1.root.json" | sha256sum | awk '{print $1}')
            cosign initialize \
                --mirror="${TAS_TUF_URL}" \
                --root="${TAS_TUF_URL}/1.root.json" \
                --root-checksum="${ROOT_CHECKSUM}"

            echo "TUF initialized successfully"
        '''
    }
}
```

**CRITICAL:** After `cosign initialize`, TUF mode is enabled (`--use-signing-config=true`
by default). All subsequent `cosign sign`, `cosign attest`, and `cosign verify` commands
automatically use TUF-provided service URLs. Do NOT pass explicit URL flags like
`--fulcio-url`, `--rekor-url`, or `--oidc-issuer` as they conflict with TUF mode and
cause "cannot specify service URLs and use signing config" errors with Red Hat cosign 3.x.

---

**Keycloak Signing Stage Snippets:**

Generate the signing stage with conditional token acquisition for Keycloak providers.

**CRITICAL:** Use TUF mode (no explicit URL flags) per `redhat-cosign-tuf-patterns.md`.

**For confidential clients (TUF mode):**

```groovy
stage('Sign Image') {
    steps {
        withCredentials([string(credentialsId: 'oidc-client-secret', variable: 'OIDC_CLIENT_SECRET')]) {
            script {
                def IDENTITY_TOKEN = sh(
                    script: """
                        export SSL_CERT_FILE=/tmp/tuf-ca.crt
                        export CURL_CA_BUNDLE=/tmp/tuf-ca.crt
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
                    export SSL_CERT_FILE=/tmp/tuf-ca.crt
                    export CURL_CA_BUNDLE=/tmp/tuf-ca.crt
                    export COSIGN_YES=true
                    export COSIGN_OIDC_CLIENT_ID=\${OIDC_CLIENT_ID}
                    export SIGSTORE_ID_TOKEN=${IDENTITY_TOKEN}
                    
                    cosign sign \${IMAGE_REFERENCE}
                """
            }
        }
    }
}
```

**For public clients (TUF mode):**

```groovy
stage('Sign Image') {
    steps {
        withCredentials([
            usernamePassword(credentialsId: 'oidc-user-credentials', 
                           usernameVariable: 'OIDC_USER', 
                           passwordVariable: 'OIDC_PASSWORD')
        ]) {
            script {
                def IDENTITY_TOKEN = sh(
                    script: """
                        export SSL_CERT_FILE=/tmp/tuf-ca.crt
                        export CURL_CA_BUNDLE=/tmp/tuf-ca.crt
                        curl -s -X POST \
                          "\${TAS_OIDC_ISSUER}/protocol/openid-connect/token" \
                          -d "grant_type=password" \
                          -d "client_id=\${OIDC_CLIENT_ID}" \
                          -d "username=\${OIDC_USER}" \
                          -d "password=\${OIDC_PASSWORD}" \
                          -d "scope=openid email" \
                          | jq -r '.access_token'
                    """,
                    returnStdout: true
                ).trim()

                sh """
                    export SSL_CERT_FILE=/tmp/tuf-ca.crt
                    export CURL_CA_BUNDLE=/tmp/tuf-ca.crt
                    export COSIGN_YES=true
                    export COSIGN_OIDC_CLIENT_ID=\${OIDC_CLIENT_ID}
                    export SIGSTORE_ID_TOKEN=${IDENTITY_TOKEN}
                    
                    cosign sign \${IMAGE_REFERENCE}
                """
            }
        }
    }
}
```

**Note:** Include both snippet variants in the blueprint with clear conditional
headers indicating which one applies based on the detected client type. If client
type is `unknown`, default to the public client snippet with a warning note.

**Important:** The Initialize TUF stage (from Step 8b) runs once before signing and
sets up the signing config. After `cosign initialize`, all subsequent `cosign sign`,
`cosign attest`, and `cosign verify` commands automatically use TUF-provided service
URLs via `--use-signing-config=true` (the default). Do NOT pass explicit URL flags
like `--fulcio-url`, `--rekor-url`, or `--oidc-issuer` as they conflict with TUF mode.

Generate the verification stage — run `cosign verify` with certificate identity.

**TUF mode (after `cosign initialize`):** Use only certificate flags, no URL flags:

```groovy
stage('Verify Image') {
    steps {
        sh """
            export SSL_CERT_FILE=/tmp/tuf-ca.crt
            export CURL_CA_BUNDLE=/tmp/tuf-ca.crt
            
            cosign verify \
              --certificate-identity=\${EXPECTED_IDENTITY} \
              --certificate-oidc-issuer=\${OIDC_ISSUER} \
              \${IMAGE_REFERENCE}
        """
    }
}
```

Generate the attestation stage — run `cosign attest` with SBOM predicates (TUF mode).

**For confidential clients (TUF mode):**

```groovy
stage('Attest Image') {
    steps {
        withCredentials([string(credentialsId: 'oidc-client-secret', variable: 'OIDC_CLIENT_SECRET')]) {
            script {
                def IDENTITY_TOKEN = sh(
                    script: """
                        export SSL_CERT_FILE=/tmp/tuf-ca.crt
                        export CURL_CA_BUNDLE=/tmp/tuf-ca.crt
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
                    export SSL_CERT_FILE=/tmp/tuf-ca.crt
                    export CURL_CA_BUNDLE=/tmp/tuf-ca.crt
                    export COSIGN_YES=true
                    export COSIGN_OIDC_CLIENT_ID=\${OIDC_CLIENT_ID}
                    export SIGSTORE_ID_TOKEN=${IDENTITY_TOKEN}
                    
                    cosign attest \
                      --predicate=\${SBOM_FILE} \
                      --type=spdxjson \
                      \${IMAGE_REFERENCE}
                """
            }
        }
    }
}
```

**For public clients:**

```groovy
stage('Attest Image') {
    steps {
        withCredentials([
            usernamePassword(credentialsId: 'oidc-user-credentials', 
                           usernameVariable: 'OIDC_USER', 
                           passwordVariable: 'OIDC_PASSWORD')
        ]) {
            script {
                def IDENTITY_TOKEN = sh(
                    script: """
                        curl -s -X POST \
                          "\${TAS_OIDC_ISSUER}/protocol/openid-connect/token" \
                          -d "grant_type=password" \
                          -d "client_id=\${OIDC_CLIENT_ID}" \
                          -d "username=\${OIDC_USER}" \
                          -d "password=\${OIDC_PASSWORD}" \
                          -d "scope=openid email" \
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
}
```

---

**Explicit URL Mode Snippets (when TUF not available or customer requests it):**

If TUF is not available or customer explicitly requests `--use-signing-config=false`,
generate these snippets instead (no `cosign initialize`, explicit URL flags with
`--use-signing-config=false`).

**Note:** Even without TUF, you still need to extract and trust the TAS server CA
certificate for HTTPS calls. Add this to the beginning of the Sign stage or as a
separate preparation stage:

```groovy
stage('Prepare TAS CA Certificate') {
    steps {
        echo 'Extracting TAS server CA certificate for TLS verification...'
        sh '''
            # Extract CA certificate from any TAS endpoint
            TAS_HOST=$(echo "${TAS_FULCIO_URL}" | sed 's|^https://||' | cut -d/ -f1)
            echo | openssl s_client -showcerts -connect "${TAS_HOST}:443" 2>/dev/null \
                | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > /tmp/tuf-ca.crt
        '''
    }
}
```

**For confidential clients (Explicit URL mode):**

```groovy
stage('Sign Image') {
    steps {
        withCredentials([string(credentialsId: 'oidc-client-secret', variable: 'OIDC_CLIENT_SECRET')]) {
            script {
                def IDENTITY_TOKEN = sh(
                    script: """
                        export SSL_CERT_FILE=/tmp/tuf-ca.crt
                        export CURL_CA_BUNDLE=/tmp/tuf-ca.crt
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
                    export SSL_CERT_FILE=/tmp/tuf-ca.crt
                    export CURL_CA_BUNDLE=/tmp/tuf-ca.crt
                    
                    cosign sign \
                      --use-signing-config=false \
                      --fulcio-url=\${TAS_FULCIO_URL} \
                      --rekor-url=\${TAS_REKOR_URL} \
                      --oidc-issuer=\${TAS_OIDC_ISSUER} \
                      --oidc-client-id=\${OIDC_CLIENT_ID} \
                      --identity-token=${IDENTITY_TOKEN} \
                      --yes \
                      \${IMAGE_REFERENCE}
                """
            }
        }
    }
}
```

**For public clients (Explicit URL mode):**

```groovy
stage('Sign Image') {
    steps {
        withCredentials([
            usernamePassword(credentialsId: 'oidc-user-credentials', 
                           usernameVariable: 'OIDC_USER', 
                           passwordVariable: 'OIDC_PASSWORD')
        ]) {
            script {
                def IDENTITY_TOKEN = sh(
                    script: """
                        export SSL_CERT_FILE=/tmp/tuf-ca.crt
                        export CURL_CA_BUNDLE=/tmp/tuf-ca.crt
                        curl -s -X POST \
                          "\${TAS_OIDC_ISSUER}/protocol/openid-connect/token" \
                          -d "grant_type=password" \
                          -d "client_id=\${OIDC_CLIENT_ID}" \
                          -d "username=\${OIDC_USER}" \
                          -d "password=\${OIDC_PASSWORD}" \
                          -d "scope=openid email" \
                          | jq -r '.access_token'
                    """,
                    returnStdout: true
                ).trim()

                sh """
                    export SSL_CERT_FILE=/tmp/tuf-ca.crt
                    export CURL_CA_BUNDLE=/tmp/tuf-ca.crt
                    
                    cosign sign \
                      --use-signing-config=false \
                      --fulcio-url=\${TAS_FULCIO_URL} \
                      --rekor-url=\${TAS_REKOR_URL} \
                      --oidc-issuer=\${TAS_OIDC_ISSUER} \
                      --oidc-client-id=\${OIDC_CLIENT_ID} \
                      --identity-token=${IDENTITY_TOKEN} \
                      --yes \
                      \${IMAGE_REFERENCE}
                """
            }
        }
    }
}
```

**Verify stage (Explicit URL mode):**

```groovy
stage('Verify Image') {
    steps {
        sh """
            export SSL_CERT_FILE=/tmp/tuf-ca.crt
            export CURL_CA_BUNDLE=/tmp/tuf-ca.crt
            
            cosign verify \
              --use-signing-config=false \
              --rekor-url=\${TAS_REKOR_URL} \
              --certificate-identity=\${EXPECTED_IDENTITY} \
              --certificate-oidc-issuer=\${TAS_OIDC_ISSUER} \
              \${IMAGE_REFERENCE}
        """
    }
}
```

**Attest stage (Explicit URL mode):**

Follow the same pattern as Sign stage, but replace `cosign sign` with:

```bash
cosign attest \
  --use-signing-config=false \
  --fulcio-url=\${TAS_FULCIO_URL} \
  --rekor-url=\${TAS_REKOR_URL} \
  --oidc-issuer=\${TAS_OIDC_ISSUER} \
  --oidc-client-id=\${OIDC_CLIENT_ID} \
  --identity-token=${IDENTITY_TOKEN} \
  --predicate=\${SBOM_FILE} \
  --type=spdxjson \
  --yes \
  \${IMAGE_REFERENCE}
```

**Note:** Explicit URL mode requires setting all service URLs as environment variables
in the pipeline (TAS_FULCIO_URL, TAS_REKOR_URL, TAS_TSA_URL, TAS_OIDC_ISSUER).

---

**Non-Keycloak Provider Guidance:**

For non-Keycloak providers, generate a guidance section in the blueprint instead of
Jenkinsfile snippets. Use the templates below based on `oidc_provider_type`:

**GitHub Actions:**
```markdown
## ⚠️ GitHub Actions OIDC Detected

Your RHTAS deployment is configured with GitHub Actions as the OIDC provider:
- **Issuer:** {{oidc_issuer}}
- **Client ID:** {{oidc_client_id}}

**Jenkins Limitation:** Jenkins does not provide native integration with GitHub
Actions OIDC. GitHub Actions OIDC tokens are only available within GitHub Actions
workflows.

**Recommended Approach:**
1. **Option A (Recommended):** Configure Keycloak or Red Hat SSO as an additional
   OIDC issuer in Fulcio for Jenkins-based signing. See the RHTAS Deployment Guide
   section on "Configuring multiple OIDC issuers."

2. **Option B:** Perform signing within GitHub Actions workflows instead of Jenkins.
   Refer to the RHTAS Deployment Guide section on "Signing with GitHub Actions."
```

**Google OAuth:**
```markdown
## ⚠️ Google OAuth OIDC Detected

Your RHTAS deployment is configured with Google OAuth as the OIDC provider:
- **Issuer:** {{oidc_issuer}}
- **Client ID:** {{oidc_client_id}}

**Jenkins Limitation:** Google OAuth uses browser-based authentication flows and is
not suitable for Jenkins CI/CD automation (non-interactive pipelines).

**Recommended Approach:**
Configure Keycloak or Red Hat SSO as the OIDC issuer for CI/CD automation. Keycloak
can optionally federate to Google for interactive user authentication while providing
service account credentials for Jenkins pipelines.

Refer to the RHTAS Deployment Guide sections:
- "Configuring Keycloak OIDC Issuer"
- "Keycloak Identity Provider Federation" (optional Google integration)
```

**Microsoft Entra ID:**
```markdown
## ⚠️ Microsoft Entra ID OIDC Detected

Your RHTAS deployment is configured with Microsoft Entra ID as the OIDC provider:
- **Issuer:** {{oidc_issuer}}
- **Client ID:** {{oidc_client_id}}

**Jenkins Limitation:** Microsoft Entra ID uses browser-based authentication flows
and is not suitable for Jenkins CI/CD automation (non-interactive pipelines).

**Recommended Approach:**
Configure Keycloak or Red Hat SSO as the OIDC issuer for CI/CD automation. Keycloak
can optionally federate to Microsoft Entra ID for interactive user authentication
while providing service account credentials for Jenkins pipelines.

Refer to the RHTAS Deployment Guide sections:
- "Configuring Keycloak OIDC Issuer"
- "Configuring Microsoft Entra ID" (for user federation)
```

**AWS STS:**
```markdown
## ⚠️ Amazon STS OIDC Detected

Your RHTAS deployment is configured with Amazon Security Token Service:
- **Issuer:** {{oidc_issuer}}
- **Client ID:** {{oidc_client_id}}

**Jenkins Limitation:** AWS STS uses Kubernetes service account tokens and requires
pods running in an EKS cluster with IAM roles for service accounts (IRSA) configured.

**Recommended Approach:**
1. **If Jenkins runs on EKS:** Configure Jenkins pod service accounts and refer to
   the RHTAS Deployment Guide section on "Signing with Amazon STS."

2. **If Jenkins runs elsewhere:** Configure Keycloak or Red Hat SSO as an additional
   OIDC issuer for Jenkins-based signing.
```

**GitLab (Native OIDC):**
```markdown
## ⚠️ GitLab Native OIDC Detected

Your RHTAS deployment is configured with GitLab native OIDC:
- **Issuer:** {{oidc_issuer}}
- **Client ID:** {{oidc_client_id}}

**Jenkins Limitation:** Jenkins does not provide native integration with GitLab OIDC.
GitLab OIDC tokens (`id_tokens` keyword) are only available within GitLab CI pipelines.

**Recommended Approach:**
1. **Option A (Recommended):** Configure Keycloak or Red Hat SSO as an additional
   OIDC issuer in Fulcio for Jenkins-based signing.

2. **Option B:** Perform signing within GitLab CI pipelines instead of Jenkins.
   Refer to the RHTAS Deployment Guide section on "Signing with GitLab CI."
```

**Generic OIDC Provider:**
```markdown
## ⚠️ Generic OIDC Provider Detected

Your RHTAS deployment is configured with a custom OIDC provider:
- **Issuer:** {{oidc_issuer}}
- **Client ID:** {{oidc_client_id}}

**Jenkins Integration:** Token acquisition depends on your OIDC provider's
supported grant types. Jenkins requires programmatic token access (non-interactive).

**Recommended Approaches:**
1. Check if your OIDC provider supports `client_credentials` grant (service accounts)
   or `password` grant (resource owner credentials).

2. Consult your OIDC provider's documentation for CI/CD integration patterns.

3. For enterprise Jenkins deployments, consider using Keycloak or Red Hat SSO, which
   provide well-tested CI/CD integration patterns and can federate to your existing
   identity provider.

Refer to the RHTAS Deployment Guide section on "Configuring custom OIDC issuers."
```

---

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
| [`shared/knowledge-base/gap-detection-rules.md`](../../shared/knowledge-base/gap-detection-rules.md) | Evaluate all 25 gap checks across 6 categories |
| [`shared/knowledge-base/redhat-cosign-tuf-patterns.md`](../../shared/knowledge-base/redhat-cosign-tuf-patterns.md) | **CRITICAL:** Choose between TUF mode vs explicit URL mode for Red Hat cosign 3.x to avoid "cannot specify service URLs and use signing config" errors |
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

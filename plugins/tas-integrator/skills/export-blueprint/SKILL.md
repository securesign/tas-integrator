---
name: export-blueprint
description: |
  Format raw blueprint data from scanner skills into a Markdown or YAML integration blueprint.
---

# export-blueprint

Accept raw blueprint data from a scanner skill, format it using templates in
`shared/templates/`, append a metadata block, and output the result as
Markdown or YAML. Generate a validation command summary with
`cosign sign`/`cosign verify` and `rekor-cli` commands using patterns from
[`shared/knowledge-base/cosign-signing-patterns.md`](../../shared/knowledge-base/cosign-signing-patterns.md).

---

## Invocation

```
/tas-integrator:export-blueprint
```

Run this after a scanner skill finishes analysing a CI/CD environment, or
invoke it directly when raw blueprint data is already available.

---

## Inputs

Require a **blueprint data object** — either inline in the prompt or via a
JSON/YAML file. Parse two top-level sections:

### `header`

Use these values to populate the common header template
([shared/templates/blueprint-header.md](../../shared/templates/blueprint-header.md)).

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `scan_timestamp` | string | yes | Set ISO 8601 timestamp of the scan |
| `environment_type` | string | yes | Set to `openshift`, `rhel`, or `kubernetes` |
| `cicd_platform` | string | yes | Set detected CI/CD platform name |
| `agent_version` | string | yes | Set TAS Integrator plugin version |
| `overall_confidence` | string | yes | Set overall confidence score (e.g. `High`) |
| `overall_details` | string | yes | Provide one-line explanation |
| `detection_confidence` | string | yes | Set detection confidence score |
| `detection_details` | string | yes | Provide one-line explanation |
| `compatibility_confidence` | string | yes | Set compatibility confidence score |
| `compatibility_details` | string | yes | Provide one-line explanation |
| `executive_summary` | string | yes | Write multi-sentence executive summary |

### `platform`

Use these values to populate the platform-specific template. Select the
template by `cicd_platform`:

| `cicd_platform` value | Template |
|-----------------------|----------|
| `jenkins` | [shared/templates/jenkins-blueprint.md](../../shared/templates/jenkins-blueprint.md) |
| `gitlab-ci` | [shared/templates/gitlab-ci-blueprint.md](../../shared/templates/gitlab-ci-blueprint.md) |

Ensure every `{{placeholder}}` marker in the selected template has a
corresponding key in the `platform` object. Use `snake_case` for placeholder
names.

### `gaps` (optional)

Accept an array of gap-detection results. Parse each entry as:

| Field | Type | Description |
|-------|------|-------------|
| `rule_id` | string | Gap rule identifier (e.g. `INFRA-001`) |
| `category` | string | Rule category code |
| `severity` | string | `Critical`, `High`, `Medium`, or `Low` |
| `status` | string | `pass`, `fail`, or `skip` |
| `details` | string | One-line finding |

### `endpoints` (optional)

Use detected TAS endpoint URLs to populate the validation command summary.

| Field | Type | Description |
|-------|------|-------------|
| `rekor_url` | string | Set Rekor server base URL |
| `fulcio_url` | string | Set Fulcio server base URL |
| `tsa_url` | string | Set Timestamp Authority base URL |
| `tuf_url` | string | Set TUF mirror base URL |
| `oidc_issuer` | string | Set OIDC token issuer URL |
| `oidc_client_id` | string | Set OIDC client ID |

---

## Processing Steps

### Step 1 — Validate Inputs

1. Verify `header` contains all required fields. If any are missing, list the
   gaps and stop.
2. Verify `cicd_platform` maps to a known template. If not, list the supported
   platforms and stop.
3. Verify `platform` contains a key for every `{{placeholder}}` in the selected
   template. If any are missing, list them and stop.

### Step 2 — Render Header

Read [`shared/templates/blueprint-header.md`](../../shared/templates/blueprint-header.md)
and replace each
`{{placeholder}}` marker with the corresponding value from `header`.

### Step 3 — Render Platform Section

Read the platform template selected in Step 1 (e.g.
[`shared/templates/jenkins-blueprint.md`](../../shared/templates/jenkins-blueprint.md) or
[`shared/templates/gitlab-ci-blueprint.md`](../../shared/templates/gitlab-ci-blueprint.md)) and replace each `{{placeholder}}`
marker with the corresponding value from `platform`.

Expand repeating rows (tables where a placeholder represents one row in a
multi-row table) once per item in the provided array value.

### Step 4 — Append Gap Assessment Summary

If `gaps` is provided, append a **Gap Assessment Summary** section after the
platform section:

```markdown
## Gap Assessment Summary

| Rule | Category | Severity | Status | Details |
|------|----------|----------|--------|---------|
| INFRA-001 | INFRA | Critical | pass | TAS deployment detected |
| OIDC-001 | OIDC | Critical | fail | No OIDC issuer configured |
```

Sort rows by category in the order: `INFRA`, `OIDC`, `SIGN`, `VERIFY`,
`POLICY`, `SUPPLY`. Within each category, sort by severity (Critical first).

After the table, add a severity summary:

```markdown
**Results:** X passed, Y failed, Z skipped
**Critical gaps:** list of failing critical rule IDs or "None"
```

### Step 5 — Append Validation Command Summary

Append a **Validation Commands** section using command patterns from
[`shared/knowledge-base/cosign-signing-patterns.md`](../../shared/knowledge-base/cosign-signing-patterns.md) and endpoint formats from
[`shared/knowledge-base/tas-endpoint-config.md`](../../shared/knowledge-base/tas-endpoint-config.md). Substitute endpoint URLs from
`endpoints` when provided; otherwise insert `{{placeholder}}` markers so the
user can fill them in manually.

#### Endpoint Health Checks

```markdown
### Endpoint Health Checks

| Component | Command | Expected |
|-----------|---------|----------|
| Fulcio | `curl -s -o /dev/null -w "%{http_code}" {{fulcio_url}}/healthz` | `200` |
| Rekor | `curl -s -o /dev/null -w "%{http_code}" {{rekor_url}}/api/v1/log` | `200` |
| TSA | `curl -s -o /dev/null -w "%{http_code}" {{tsa_url}}/api/v1/timestamp/certchain` | `200` |
| TUF | `curl -s -o /dev/null -w "%{http_code}" {{tuf_url}}/root.json` | `200` |
```

#### TUF Initialization

```markdown
### TUF Initialization

cosign initialize --mirror={{tuf_url}} --root={{tuf_url}}/root.json
```

#### Signing Test

```markdown
### Signing Test

cosign sign \
  --fulcio-url={{fulcio_url}} \
  --rekor-url={{rekor_url}} \
  --oidc-issuer={{oidc_issuer}} \
  --oidc-client-id={{oidc_client_id}} \
  --identity-token=$(cat /path/to/token) \
  --yes \
  {{image_reference}}
```

#### Verification Test

```markdown
### Verification Test

cosign verify \
  --rekor-url={{rekor_url}} \
  --certificate-identity={{expected_identity}} \
  --certificate-oidc-issuer={{oidc_issuer}} \
  {{image_reference}}
```

#### Transparency Log Lookup

```markdown
### Transparency Log Lookup

rekor-cli get --rekor_server={{rekor_url}} --log-index={{log_index}}

rekor-cli search --rekor_server={{rekor_url}} --email={{signer_identity}}
```

### Step 6 — Append Metadata Block

Append a metadata footer at the end of the document:

```markdown
---

## Blueprint Metadata

| Field | Value |
|-------|-------|
| **Generated By** | TAS Integrator v{{agent_version}} |
| **Scan Timestamp** | {{scan_timestamp}} |
| **CI/CD Platform** | {{cicd_platform}} |
| **Environment Type** | {{environment_type}} |
| **Template Version** | {{template_version}} |
| **Output Format** | {{output_format}} |
```

Read `template_version` from [`.claude-plugin/plugin.json`](../../.claude-plugin/plugin.json).
Set `output_format` to `markdown`
or `yaml` based on the chosen output mode.

### Step 7 — Output

Select one of three output modes via the `output` parameter. Default to
`display` if not specified.

#### `display` (default)

Print the assembled blueprint as Markdown directly in the conversation.
Do not write any file.

#### `save`

Write the assembled blueprint to a file. Use the `output_path` parameter if
provided, otherwise generate the default path:

```
blueprint-{{cicd_platform}}-{{scan_timestamp}}.md
```

For YAML output, change the extension to `.yaml` and convert as follows:

```
blueprint-{{cicd_platform}}-{{scan_timestamp}}.yaml
```

When saving as YAML, convert the Markdown blueprint into a structured YAML
document. Map each section heading to a top-level key and nest fields
accordingly:

```yaml
blueprint:
  header:
    scan_timestamp: "2024-01-15T10:30:00Z"
    environment_type: "openshift"
    cicd_platform: "jenkins"
    agent_version: "0.1.0"
    confidence:
      overall:
        score: "High"
        details: "All components detected"
      detection:
        score: "High"
        details: "Jenkins environment confirmed"
      compatibility:
        score: "Medium"
        details: "Plugin version requires update"
    executive_summary: "..."

  platform:
    prerequisites: [...]
    plugins: [...]
    credentials: [...]
    pipeline_stages:
      signing: "..."
      verification: "..."
      attestation: "..."
    validation_commands: [...]
    checklist: [...]

  gaps:
    summary:
      passed: 18
      failed: 4
      skipped: 2
      critical_gaps: ["OIDC-001", "SIGN-002"]
    rules: [...]

  validation_commands:
    health_checks: [...]
    tuf_init: "..."
    signing_test: "..."
    verification_test: "..."
    rekor_lookup: "..."

  metadata:
    generated_by: "TAS Integrator v0.1.0"
    scan_timestamp: "2024-01-15T10:30:00Z"
    template_version: "0.1.0"
    output_format: "yaml"
```

#### `both`

Execute both `display` and `save` modes. Print the blueprint in the
conversation and write it to file.

---

## Output Format Parameter

| Parameter | Values | Default | Description |
|-----------|--------|---------|-------------|
| `output` | `display`, `save`, `both` | `display` | Control where to send the result |
| `format` | `markdown`, `yaml` | `markdown` | Select the document format |
| `output_path` | file path | auto-generated | Specify file path for `save` and `both` modes |

---

## Validation Command Reference

Generate the validation command summary by reading two knowledge-base files:

- Read [`shared/knowledge-base/cosign-signing-patterns.md`](../../shared/knowledge-base/cosign-signing-patterns.md)
  for `cosign sign`, `cosign verify`, and `cosign attest` command patterns with
  TAS-specific flags
- Read [`shared/knowledge-base/tas-endpoint-config.md`](../../shared/knowledge-base/tas-endpoint-config.md)
  for endpoint URL formats, health check commands, and CI/CD variable mapping

### cosign Commands to Include

Include these `cosign` commands in the validation summary:

| Command | Use to |
|---------|--------|
| `cosign initialize` | Initialize TUF root of trust for the TAS instance |
| `cosign sign` | Sign a container image using keyless (Fulcio) signing |
| `cosign verify` | Verify a signed container image |
| `cosign attest` | Attach an attestation to a container image |

### rekor-cli Commands to Include

Include these `rekor-cli` commands in the validation summary:

| Command | Use to |
|---------|--------|
| `rekor-cli get` | Retrieve a transparency log entry by index or UUID |
| `rekor-cli search` | Search the transparency log by email or artifact hash |

---

## Error Handling

| Condition | Action |
|-----------|--------|
| Missing required `header` field | List missing fields and stop |
| Unknown `cicd_platform` | List supported platforms and stop |
| Missing `platform` placeholder | List missing keys and stop |
| Template file not found | Report missing template path and stop |
| `output_path` not writable | Report permission error for the target path and stop |
| `gaps` provided but empty array | Skip gap summary section, proceed |
| `endpoints` not provided | Insert `{{placeholder}}` markers in validation commands |

---

## Examples

### Minimal Invocation (Display Only)

Render the blueprint directly in the conversation using default settings:

```
/tas-integrator:export-blueprint

Blueprint data:
- header:
    scan_timestamp: "2024-01-15T10:30:00Z"
    environment_type: "openshift"
    cicd_platform: "jenkins"
    agent_version: "0.1.0"
    overall_confidence: "High"
    overall_details: "All TAS components detected and healthy"
    detection_confidence: "High"
    detection_details: "Jenkins 2.426.3 with Pipeline plugin"
    compatibility_confidence: "High"
    compatibility_details: "All prerequisites met"
    executive_summary: "Jenkins environment is ready for TAS integration."
- platform:
    jenkins_version_status: "OK"
    jenkins_version_details: "2.426.3"
    ...remaining platform placeholders...
```

### Save as YAML

Write the blueprint to a YAML file using `--format=yaml`:

```
/tas-integrator:export-blueprint --output=save --format=yaml

Blueprint data: (as above)
```

### Display and Save with Custom Path

Print the blueprint and write it to a custom output path:

```
/tas-integrator:export-blueprint --output=both --output_path=./reports/tas-blueprint.md

Blueprint data: (as above)
```

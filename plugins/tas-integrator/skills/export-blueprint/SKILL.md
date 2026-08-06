---
name: export-blueprint
description: |
  Format raw blueprint data from scanner skills into a Markdown or YAML integration blueprint.
---

# export-blueprint

Accepts raw blueprint data from scanner skills, formats it using shared
templates, appends a metadata block, and outputs the result as Markdown or
YAML. Provides a validation command summary with cosign sign/verify and
rekor-cli commands.

---

## Invocation

```
/tas-integrator:export-blueprint
```

The skill is typically called by a scanner skill after it finishes analysing a
CI/CD environment. It can also be invoked directly when raw blueprint data is
already available.

---

## Inputs

The caller must provide a **blueprint data object** — either inline in the
prompt or via a JSON/YAML file. The object has two top-level sections:

### `header`

Values for the common header template
([shared/templates/blueprint-header.md](../../shared/templates/blueprint-header.md)).

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `scan_timestamp` | string | yes | ISO 8601 timestamp of the scan |
| `environment_type` | string | yes | e.g. `openshift`, `rhel`, `kubernetes` |
| `cicd_platform` | string | yes | Detected CI/CD platform name |
| `agent_version` | string | yes | TAS Integrator plugin version |
| `overall_confidence` | string | yes | Overall confidence score (e.g. `High`) |
| `overall_details` | string | yes | One-line explanation |
| `detection_confidence` | string | yes | Detection confidence score |
| `detection_details` | string | yes | One-line explanation |
| `compatibility_confidence` | string | yes | Compatibility confidence score |
| `compatibility_details` | string | yes | One-line explanation |
| `executive_summary` | string | yes | Multi-sentence executive summary |

### `platform`

Values for the platform-specific template. The template is selected by
`cicd_platform`:

| `cicd_platform` value | Template |
|-----------------------|----------|
| `jenkins` | [shared/templates/jenkins-blueprint.md](../../shared/templates/jenkins-blueprint.md) |
| `gitlab-ci` | [shared/templates/gitlab-ci-blueprint.md](../../shared/templates/gitlab-ci-blueprint.md) |

All `{{placeholder}}` markers in the selected template must have a
corresponding key in the `platform` object. Placeholder names use
`snake_case`.

### `gaps` (optional)

An array of gap-detection results. Each entry has:

| Field | Type | Description |
|-------|------|-------------|
| `rule_id` | string | Gap rule identifier (e.g. `INFRA-001`) |
| `category` | string | Rule category code |
| `severity` | string | `Critical`, `High`, `Medium`, or `Low` |
| `status` | string | `pass`, `fail`, or `skip` |
| `details` | string | One-line finding |

### `endpoints` (optional)

Detected TAS endpoint URLs. Used to populate the validation command summary.

| Field | Type | Description |
|-------|------|-------------|
| `rekor_url` | string | Rekor server base URL |
| `fulcio_url` | string | Fulcio server base URL |
| `tsa_url` | string | Timestamp Authority base URL |
| `tuf_url` | string | TUF mirror base URL |
| `oidc_issuer` | string | OIDC token issuer URL |
| `oidc_client_id` | string | OIDC client ID |

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

Read [shared/templates/blueprint-header.md](../../shared/templates/blueprint-header.md) and replace each
`{{placeholder}}` marker with the corresponding value from `header`.

### Step 3 — Render Platform Section

Read the platform template selected in Step 1 and replace each
`{{placeholder}}` marker with the corresponding value from `platform`.

For repeating rows (tables where a placeholder represents one row in a
multi-row table), expand the row once per item in the provided array value.

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

Group rows by category in the order: `INFRA`, `OIDC`, `SIGN`, `VERIFY`,
`POLICY`, `SUPPLY`. Within each category, sort by severity (Critical first).

After the table, append a severity summary:

```markdown
**Results:** X passed, Y failed, Z skipped
**Critical gaps:** list of failing critical rule IDs or "None"
```

### Step 5 — Append Validation Command Summary

Append a **Validation Commands** section with cosign and rekor-cli commands
that the user can run to verify a working TAS integration. Use endpoint URLs
from `endpoints` when provided; otherwise use `{{placeholder}}` markers so the
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

`template_version` is the version string from
[.claude-plugin/plugin.json](../../.claude-plugin/plugin.json). `output_format` is `markdown` or `yaml`
depending on the chosen output mode.

### Step 7 — Output

The skill supports three output modes. The caller specifies the mode via the
`output` parameter. If not specified, default to `display`.

#### `display` (default)

Render the assembled blueprint as Markdown directly in the conversation.
Do not write any file.

#### `save`

Write the assembled blueprint to a file. The caller provides a file path via
the `output_path` parameter, or the skill uses the default:

```
blueprint-{{cicd_platform}}-{{scan_timestamp}}.md
```

For YAML output, change the extension to `.yaml` and convert the document:

```
blueprint-{{cicd_platform}}-{{scan_timestamp}}.yaml
```

When saving as YAML, convert the Markdown blueprint into a structured YAML
document with top-level keys matching the section headings:

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

Perform both `display` and `save`. Render in the conversation and write to
file.

---

## Output Format Parameter

| Parameter | Values | Default | Description |
|-----------|--------|---------|-------------|
| `output` | `display`, `save`, `both` | `display` | Where to send the result |
| `format` | `markdown`, `yaml` | `markdown` | Document format |
| `output_path` | file path | auto-generated | File path for `save` and `both` modes |

---

## Validation Command Reference

The validation command summary draws from two knowledge-base files:

- [shared/knowledge-base/cosign-signing-patterns.md](../../shared/knowledge-base/cosign-signing-patterns.md) — cosign sign, verify,
  and attest command patterns with TAS-specific flags
- [shared/knowledge-base/tas-endpoint-config.md](../../shared/knowledge-base/tas-endpoint-config.md) — endpoint URL formats,
  health check commands, and CI/CD variable mapping

### cosign Commands Included

| Command | Purpose |
|---------|---------|
| `cosign initialize` | Initialize TUF root of trust for the TAS instance |
| `cosign sign` | Sign a container image using keyless (Fulcio) signing |
| `cosign verify` | Verify a signed container image |
| `cosign attest` | Attach an attestation to a container image |

### rekor-cli Commands Included

| Command | Purpose |
|---------|---------|
| `rekor-cli get` | Retrieve a transparency log entry by index or UUID |
| `rekor-cli search` | Search the transparency log by email or artifact hash |

---

## Error Handling

| Condition | Behaviour |
|-----------|-----------|
| Missing required `header` field | List missing fields, stop |
| Unknown `cicd_platform` | List supported platforms, stop |
| Missing `platform` placeholder | List missing keys, stop |
| Template file not found | Report missing template path, stop |
| `output_path` not writable | Report permission error, stop |
| `gaps` provided but empty array | Skip gap summary section, proceed |
| `endpoints` not provided | Use `{{placeholder}}` markers in validation commands |

---

## Examples

### Minimal Invocation (Display Only)

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

```
/tas-integrator:export-blueprint --output=save --format=yaml

Blueprint data: (as above)
```

### Display and Save with Custom Path

```
/tas-integrator:export-blueprint --output=both --output_path=./reports/tas-blueprint.md

Blueprint data: (as above)
```

---
name: scan-gitlab
description: Scan GitLab projects and CI pipelines for TAS signing integrations, detect gaps, and produce a reviewable blueprint.
---

# scan-gitlab

Scan GitLab projects, groups, runners, variables, and CI configuration to
understand an existing Trusted Artifact Signer (TAS) integration. Produce
evidence-backed findings and a blueprint; do not change GitLab or the target
cluster.

## Invocation and guardrails

Use when the user asks to scan, assess, inventory, or plan TAS integration for
GitLab. Before asking for a namespace, if `kubectl` is available, inspect the
active Kubernetes context namespace read-only; if it is unset, probe the
`trusted-artifact-signer` namespace for TAS resources. If TAS is found, use that namespace for
cluster-based discovery. If not found, ask: "Is TAS deployed in a
Kubernetes/OpenShift namespace? If so, which one?" If the user provides a
namespace, use it; if not, continue without Kubernetes/OpenShift checks and use
the other configured discovery sources. Before connecting, ask for the missing
`gitlab_url` and project/group scope; authentication may be attempted
unauthenticated first.

- Read-only by default. Never create, update, delete, trigger, or retry GitLab resources.
- Treat tokens, masked/protected variables, private keys, and job logs as sensitive. Report names and locations, never values.
- Do not claim a check passed without API, file, or command evidence.
- Confirm project/group and selected namespace (active context, `trusted-artifact-signer`, or user-provided) before using `kubectl`; redact all credentials.
- Use explicit endpoint and authentication values as overrides; do not guess.

## Inputs

### Required

| Input | Description |
| --- | --- |
| `gitlab_url` | GitLab base URL |

### Optional

| Input | Default | Description |
| --- | --- | --- |
| `namespace` | — | Set Kubernetes/OpenShift namespace where TAS is deployed |
| `rekor_url` | auto-detect | Override Rekor endpoint URL |
| `fulcio_url` | auto-detect | Override Fulcio endpoint URL |
| `tuf_url` | auto-detect | Override TUF endpoint URL |
| `tsa_url` | auto-detect | Override TSA endpoint URL |
| `oidc_issuer` | auto-detect | Override OIDC issuer URL |
| `oidc_client_id` | auto-detect | Override OIDC client ID |
| `project` | — | Project path/ID for a project scan |
| `group` | — | Group path/ID for a group scan |
| `auth` | — | Optional read-only token or approved auth method |
| `ref` | default branch | Branch/tag to inspect |
| `include_group` | false | Include accessible projects in the group |
| `output` | `display` | Output mode: `display`, `save`, or `both` |
| `format` | `markdown` | Output format: `markdown` or `yaml` |
| `output_path` | auto-generated | File path for `save` and `both` modes |

## Processing Steps

If neither `project` nor `group` is supplied, ask the user to choose the
project or group scope before querying GitLab. If `auth` is omitted, try
unauthenticated read-only API access. If GitLab returns 401 or 403, ask for a
token with the required read scope and retry; never guess credentials.

### 1. Connect and discover

Validate URL, project/group, ref, and read-only access. Record GitLab version,
target, scope, and timestamp. Prefer the GitLab API and repository files.
Record inaccessible projects, refs, or API areas as limitations.

Collect runner names/tags/executors and inspect CI configuration, included
templates, child pipelines, protected variables by name/metadata, and project
settings. Do not retrieve secret values.

### 2. Scan CI configuration

Search repository and pipeline content for `cosign`, `rekor`, `fulcio`, `tsa`,
`sigstore`, `trusted-artifact-signer`, `cosign initialize`, `--mirror`,
`--root`, `--fulcio-url`, `--rekor-url`, `--oidc-issuer`,
`--use-signing-config=false`, `SIGSTORE_ID_TOKEN`, `CI_JOB_JWT_V2`,
`id_tokens`, `TAS_*`, token acquisition, CA setup, and tool installation.

Keep project/file/line or API location for every observation. Never include
secret values in evidence.

### 3. Determine signing mode and OIDC

Classify each relevant signing command as TUF, explicit URL, mixed/invalid, or
unknown. TUF mode uses `cosign initialize` and service URLs from its signing
config. Explicit URL mode uses service URL flags together with
`--use-signing-config=false`; this explicit opt-out is valid even when
`cosign initialize` ran earlier in the workspace. Only classify a command as
mixed/invalid when it uses explicit service URL flags without
`--use-signing-config=false` while a TUF signing config is active.

Use [`shared/knowledge-base/redhat-cosign-tuf-patterns.md`](../../shared/knowledge-base/redhat-cosign-tuf-patterns.md)
for the rule. GitLab's preferred OIDC mechanism is native `id_tokens`; verify
that its audience matches the TAS Fulcio client ID. Use
[`shared/knowledge-base/oidc-setup.md`](../../shared/knowledge-base/oidc-setup.md)
and [`references/oidc-and-signing.md`](references/oidc-and-signing.md).
For complete historical GitLab CI templates, provider examples, and detailed
blueprint/remediation text, load [`references/detailed-scan-reference.md`](references/detailed-scan-reference.md).

### 4. Detect TAS endpoints

Resolve values in this order: explicit inputs, GitLab CI/CD variables by name
and metadata, pipeline environment blocks, repository config, TAS resources
found in the active/default namespace, user-provided Kubernetes/OpenShift
namespace resources, and approved RHEL configuration. Record source and
confidence. If the automatic namespace probe finds no TAS resources, ask for a
namespace before skipping cluster discovery.

Check reachability without exposing bodies or credentials:

| Service | Check |
|---|---|
| TUF | `GET {{tuf_url}}/root.json` or deployment root endpoint |
| Fulcio | `GET {{fulcio_url}}/healthz` |
| Rekor | `GET {{rekor_url}}/api/v1/log` |
| TSA | `GET {{tsa_url}}/certchain` (use the TSA base URL if `tsa_url` already ends with `/api/v1/timestamp`) |
| OIDC | Discovery document at `{{oidc_issuer}}/.well-known/openid-configuration` |

Run these checks from the GitLab runner/job network when that access is
available; otherwise record the actual checking location. Record HTTP status,
TLS/CA errors, and source for every endpoint. A successful URL discovery is
not a health-check pass.

An unreachable endpoint is a finding, not proof that the service is absent.

### 5. Evaluate and generate

Apply [`shared/knowledge-base/gap-detection-rules.md`](../../shared/knowledge-base/gap-detection-rules.md).
Evaluate every applicable rule, including authentication, OIDC audience/token,
signing mode, endpoint health, runner/tool prerequisites, CA trust, protected
variables, secret hygiene, RHTAS verification trust configuration (`VERIFY-004`),
SBOM generation (`SUPPLY-001`), SBOM attestation (`SUPPLY-002`), and SLSA
provenance (`SUPPLY-003`). Preserve each rule's `pass`, `fail`, or `skip`
status. Do not treat `--private-infrastructure` as mandatory; assess the
TUF/signing configuration or trusted root used by verification. Every gap needs
severity, evidence, impact, remediation, and confidence.

Before generating a complete blueprint, load
[`references/detailed-scan-reference.md`](references/detailed-scan-reference.md)
and [`references/blueprint-data.md`](references/blueprint-data.md). Preserve
all applicable sections, pipeline templates, provider guidance, validation
steps, gap findings, and remediation material from those references; do not
omit a section merely because the corresponding gap is `pass`, `skip`, or
`unknown`.

Follow the shared blueprint data contract linked by the platform-specific
blueprint-data reference; retain `unknown` where evidence is unavailable.

### 6. Present for review

Present scope and limitations, detected integration and mode, confidence,
gaps by severity, endpoint health, and proposed next steps. Ask before any
action that modifies GitLab, the cluster, variables, or pipeline files.

## Output and error handling

Return the summary and complete blueprint when requested. For `output=save`
or `output=both`, write using the selected `format` to `output_path` (or the
auto-generated path) after confirming it is in the requested workspace.
Include timestamp and evidence index.

- Authentication failure: report status and request a read-only method; do not guess credentials.
- Permission denied or missing include/ref: record the resource and continue with accessible scope.
- Network/TLS failure: record endpoint and error class; never disable verification silently.
- Malformed data or unavailable tool: mark dependent checks unknown; do not infer success.

## References

- [`shared/knowledge-base/gap-detection-rules.md`](../../shared/knowledge-base/gap-detection-rules.md)
- [`shared/knowledge-base/oidc-setup.md`](../../shared/knowledge-base/oidc-setup.md)
- [`shared/knowledge-base/redhat-cosign-tuf-patterns.md`](../../shared/knowledge-base/redhat-cosign-tuf-patterns.md)
- [`references/oidc-and-signing.md`](references/oidc-and-signing.md)
- [`references/blueprint-data.md`](references/blueprint-data.md)
- [`references/detailed-scan-reference.md`](references/detailed-scan-reference.md)

## Examples

`scan-gitlab gitlab_url=https://gitlab.example.com project=group/project auth=<read-only-auth>`

`scan-gitlab gitlab_url=https://gitlab.example.com project=group include_group=true namespace=tas`

`scan-gitlab gitlab_url=https://gitlab.example.com project=group/project output=save format=yaml output_path=blueprint.yaml`

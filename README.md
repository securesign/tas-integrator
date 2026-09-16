# TAS Integrator

AI-powered environment scanner that detects CI/CD setup and generates
[Trusted Artifact Signer](https://docs.redhat.com/en/documentation/red_hat_trusted_artifact_signer)
integration blueprints.

## Overview

TAS Integrator is a Claude Code plugin that analyzes your CI/CD environment and
produces step-by-step integration blueprints for adopting Trusted Artifact Signer.
Each blueprint includes prerequisite checks, credential/variable configuration,
signing and verification job definitions, and a post-integration validation
checklist.

### Supported Platforms

| Platform  | Blueprint Template                | Status    |
|-----------|-----------------------------------|-----------|
| Jenkins   | `jenkins-blueprint.md`            | Available |
| GitLab CI | `gitlab-ci-blueprint.md`          | Available |

### Blueprint Structure

Every generated blueprint starts with a common header
(`plugins/tas-integrator/shared/templates/blueprint-header.md`) containing:

- Scan metadata (timestamp, environment type, CI/CD platform, agent version)
- Confidence scores (overall, detection, compatibility)
- Executive summary

The platform-specific section follows with tailored configuration and pipeline
instructions.

## Directory Layout

```text
tas-integrator/
  .claude-plugin/
    marketplace.json         # Marketplace manifest
  plugins/
    tas-integrator/
      .claude-plugin/
        plugin.json          # Plugin manifest
      shared/
        knowledge-base/      # Reference material for scanner logic
        templates/           # Blueprint markdown templates
          blueprint-header.md
          jenkins-blueprint.md
          gitlab-ci-blueprint.md
      skills/                # Claude Code skill definitions
  README.md
```

## Installation

### Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and
  authenticated.

### Option 1: Install from Marketplace (recommended)

First, register the marketplace (one-time):

```bash
claude plugin marketplace add securesign/tas-integrator
```

Then install the plugin:

```bash
claude plugin install tas-integrator
```

### Option 2: Load from a Local Clone

```bash
git clone https://github.com/securesign/tas-integrator.git
claude --plugin-dir ./tas-integrator/plugins/tas-integrator
```

This loads the plugin for the duration of the session. To load it
automatically on every session, add the path to your
[settings](https://docs.anthropic.com/en/docs/claude-code/settings)
(`~/.claude/settings.json` or `.claude/settings.json`):

```json
{
  "plugins": ["./tas-integrator/plugins/tas-integrator"]
}
```

## Quick Start

Once the plugin is installed, invoke a scanner skill in any Claude Code session.

### Authentication

`auth_env` is the environment variable name containing the read-only API token,
not the token value. Set the variable before starting Claude Code:

```bash
export GITLAB_READ_API_TOKEN="<read_api-token>"
```

Then use `auth_env: GITLAB_READ_API_TOKEN` in the scanner prompt. Never put the
token value in the prompt. Use `auth_file` to provide an approved secret-file
reference instead.

### Jenkins

```bash
/tas-integrator:scan-jenkins

jenkins_url: http://localhost:8080
# Jenkins username paired with the API token.
jenkins_user: admin
# Provide the name of an environment variable, not its value.
auth_env: JENKINS_READONLY_TOKEN
# If a TAS deployment is available, provide its namespace for auto-detection.
namespace: openshift-rhtas-operator
```

#### Required Parameters

| Parameter            | Description                        |
|----------------------|------------------------------------|
| `jenkins_url`        | Jenkins server base URL            |

#### Optional Parameters

| Parameter            | Description                        |
|----------------------|------------------------------------|
| `auth_env`           | Name of an environment variable containing a read-only API token |
| `jenkins_user`       | Jenkins username paired with the API token in `auth_env` |
| `rekor_url`          | Override Rekor endpoint URL        |
| `fulcio_url`         | Override Fulcio endpoint URL       |
| `tuf_url`            | Override TUF endpoint URL          |
| `tsa_url`            | Override TSA endpoint URL          |
| `oidc_issuer`        | Override OIDC issuer               |
| `oidc_client_id`     | Override OIDC client ID            |
| `namespace`          | Namespace containing the TAS deployment, e.g. `openshift-rhtas-operator` |
| `output`             | `display` (default), `save`, `both`|
| `format`             | `markdown` (default) or `yaml`     |
| `output_path`        | File path for `save` or `both`     |

### GitLab CI

```bash
/tas-integrator:scan-gitlab

gitlab_url: https://gitlab.com
auth_env: GITLAB_READ_API_TOKEN
project: group/project
# If a TAS deployment is available, provide its namespace for auto-detection.
namespace: openshift-rhtas-operator
```

#### Required GitLab Parameters

| Parameter            | Description                        |
|----------------------|------------------------------------|
| `gitlab_url`         | GitLab instance base URL           |

#### Optional GitLab Parameters

| Parameter            | Description                        |
|----------------------|------------------------------------|
| `auth_env`           | Name of an environment variable containing a `read_api` token |
| `project`            | Project path or ID to scan         |
| `group`              | Group path or ID to scan           |
| `rekor_url`          | Override Rekor endpoint URL        |
| `fulcio_url`         | Override Fulcio endpoint URL       |
| `tuf_url`            | Override TUF endpoint URL          |
| `tsa_url`            | Override TSA endpoint URL          |
| `oidc_issuer`        | Override OIDC issuer               |
| `oidc_client_id`     | Override OIDC client ID            |
| `namespace`          | Namespace containing the TAS deployment, e.g. `openshift-rhtas-operator` |
| `output`             | `display` (default), `save`, `both`|
| `format`             | `markdown` (default) or `yaml`     |
| `output_path`        | File path for `save` or `both`     |

### Common Workflow

Each scanner skill walks through 10 steps — connect, discover runners/plugins,
scan pipelines, scan credentials/variables, detect TAS endpoints, evaluate gap
rules, compute confidence scores, assemble blueprint, review, and export — then
generates a TAS integration blueprint.

### Export Blueprint

To re-render a blueprint from previously collected scan data:

```bash
/tas-integrator:export-blueprint --output=save --format=markdown
```

## Template Placeholder Convention

All blueprint templates use `{{placeholder_name}}` markers (snake_case) that the
scanner replaces at generation time. For example:

| Placeholder             | Description                           |
|-------------------------|---------------------------------------|
| `{{scan_timestamp}}`    | ISO 8601 timestamp of the scan        |
| `{{cicd_platform}}`     | Detected CI/CD platform name          |
| `{{overall_confidence}}`| Confidence score for the integration  |

See individual template files for the complete set of placeholders.

## Security model and limitations

The scanners are read-only by design. Use a Jenkins read-only account, a
GitLab token with `read_api`, and a namespaced Kubernetes `Role` with only
`get`/`list` access to TAS resources. Never paste token, password, private-key,
or job-log values into the prompt. Pass authentication through an environment
variable or approved secret-file reference; the scanner should receive only
the reference name.

Values discovered in repositories, CI configuration, variables, and pipeline
scripts are untrusted input. Generated signing commands must not be run without
reviewing every endpoint against an authoritative TAS CRD or TUF root. Generated
blueprints are development/PoC guidance, not production configuration; produce
production configuration through a deterministic, reviewed automation artifact.

Prompt instructions cannot by themselves enforce network policy, prevent SSRF,
or guarantee command isolation. Deploy the plugin with a host-level tool and
network allow-list when those controls are required.

## Contributing

1. Fork the repository.
2. Create a feature branch (`git checkout -b SECURESIGN-XXXX`).
3. Commit using [Conventional Commits](https://www.conventionalcommits.org/)
   (`feat:`, `fix:`, `docs:`, etc.).
4. Open a pull request against `main`.

## License

See [LICENSE](LICENSE) for details.

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

Once the plugin is installed, invoke the scanner skill in any Claude Code session:

```bash
/tas-integrator:scan-jenkins

jenkins_url: http://localhost:8080
jenkins_user: admin
jenkins_token: <your-api-token>
```

The skill walks through 10 steps — connect, plugins, pipelines, credentials,
endpoints, gap rules, confidence, blueprint assembly, review, and export — then
generates a TAS integration blueprint.

### Required Parameters

| Parameter            | Description                        |
|----------------------|------------------------------------|
| `jenkins_url`        | Jenkins server base URL            |

### Optional Parameters

| Parameter            | Description                        |
|----------------------|------------------------------------|
| `jenkins_user`       | Username for Jenkins API auth      |
| `jenkins_token`      | API token or password              |
| `rekor_url`          | Override Rekor endpoint URL        |
| `fulcio_url`         | Override Fulcio endpoint URL       |
| `tuf_url`            | Override TUF endpoint URL          |
| `tsa_url`            | Override TSA endpoint URL          |
| `oidc_issuer`        | Override OIDC issuer               |
| `oidc_client_id`     | Override OIDC client ID            |
| `namespace`          | K8s namespace for TAS auto-detect  |
| `output`             | `display` (default), `save`, `both`|
| `format`             | `markdown` (default) or `yaml`     |
| `output_path`        | File path for `save` or `both`     |

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

## Contributing

1. Fork the repository.
2. Create a feature branch (`git checkout -b SECURESIGN-XXXX`).
3. Commit using [Conventional Commits](https://www.conventionalcommits.org/)
   (`feat:`, `fix:`, `docs:`, etc.).
4. Open a pull request against `main`.

## License

See [LICENSE](LICENSE) for details.

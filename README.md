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

| Platform   | Blueprint Template              | Status |
|------------|---------------------------------|--------|
| Jenkins    | `shared/templates/jenkins-blueprint.md`    | Available |
| GitLab CI  | `shared/templates/gitlab-ci-blueprint.md`  | Available |

### Blueprint Structure

Every generated blueprint starts with a common header
(`shared/templates/blueprint-header.md`) containing:

- Scan metadata (timestamp, environment type, CI/CD platform, agent version)
- Confidence scores (overall, detection, compatibility)
- Executive summary

The platform-specific section follows with tailored configuration and pipeline
instructions.

## Directory Layout

```
tas-integrator/
  .claude-plugin/
    plugin.json            # Plugin manifest
  shared/
    knowledge-base/        # Reference material for scanner logic
    templates/             # Blueprint markdown templates
      blueprint-header.md
      jenkins-blueprint.md
      gitlab-ci-blueprint.md
  skills/                  # Claude Code skill definitions
  README.md
```

## Installation

### Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and
  authenticated.

### Load from a Local Clone

```bash
git clone https://github.com/securesign/tas-integrator.git
claude --plugin-dir ./tas-integrator
```

This loads the plugin for the duration of the session. To load it
automatically on every session, add it to your
[settings](https://docs.anthropic.com/en/docs/claude-code/settings):

```json
{
  "plugins": ["./tas-integrator"]
}
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

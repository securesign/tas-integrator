# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Plugin manifest (`.claude-plugin/plugin.json`).
- README with installation and usage instructions.
- Shared knowledge base: cosign signing patterns, OIDC setup, TAS endpoint
  config, deployment patterns, gap detection rules (24 rules across 6
  categories).
- Shared templates: blueprint header, Jenkins blueprint, GitLab CI blueprint.
- `export-blueprint` skill — renders scanner output into formatted blueprints.
- `scan-jenkins` skill — read-only Jenkins environment scanner with gap
  detection, confidence scoring, and Jenkinsfile snippet generation.
- `scan-gitlab` skill — read-only GitLab CI environment scanner with gap
  detection, confidence scoring, and `.gitlab-ci.yml` snippet generation.
- Brownfield integration test with mock TAS endpoints (runs on every PR).
- Full-stack E2E integration test with Kind cluster, secure-sign-operator,
  and Keycloak (manual trigger / nightly).
- Greenfield integration test for vanilla Jenkins with no TAS configuration.
- GitHub Actions CI workflows (`test-scan-jenkins.yaml`, `e2e-scan-jenkins.yaml`).
- Quick Start section in README with skill invocation examples.

### Changed

- Restructured repository as a Claude Code plugin marketplace.
- Refactored Jenkins test image to use `jenkins-plugin-cli` for build-time
  plugin installation.

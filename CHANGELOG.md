# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2025-07-23

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

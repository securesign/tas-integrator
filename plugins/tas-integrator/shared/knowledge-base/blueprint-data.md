# Blueprint data contract

Use this contract for both Jenkins and GitLab TAS blueprints. The
platform-specific `references/blueprint-data.md` files add only source-specific
evidence and secret-handling requirements.

## Required sections

Include `header`, `platform`, `scope`, `integration`, `endpoints`, `gaps`,
`confidence`, `validation`, `recommendations`, and `limitations`.

## Gaps

Each gap contains `id`, `severity`, `title`, `status`, `evidence`, `impact`,
`remediation`, and `confidence`. Evaluate and preserve every applicable rule,
including `VERIFY-004` and `SUPPLY-001` through `SUPPLY-003`; do not collapse a
failed rule into a general recommendation.

## Endpoints

Each endpoint contains `name`, `url` (or `unknown`), `source`, `health`, and
`tls_observation`. Record the discovery source and the actual health-check
result; a discovered URL alone is not a health pass.

## Validation and remediation

The `validation` section must include the command or API request, expected
result, observed result, and a post-integration checklist. Include actionable
snippets when applicable: RHTAS TUF initialization or `--trusted-root`, SBOM
generation, `cosign attest`, and SLSA provenance. Mention
`--private-infrastructure` only as a legacy compatibility option when the
detected Cosign version requires it.

Use `unknown` rather than an invented value. Keep credentials and secret values
out of the blueprint; record only identifiers, variable names, binding types,
and masked/protected metadata.

# Contributing to TAS Integrator

Thank you for your interest in contributing to the TAS Integrator plugin. This
document describes the contributors ladder, governance policies, and workflows.

## Contributors Ladder

| Role | GitHub Role | Capabilities |
|------|-------------|-------------|
| Contributor | Read | File issues, submit PRs, participate in discussions |
| Reviewer | Write | Review/approve PRs, push to non-protected branches, triage issues |
| Maintainer | Maintain | Merge PRs, manage releases, configure branch protection, maintain CI |
| Owner | Admin | Manage repo settings, grant/revoke roles, governance decisions |

## Current Contributors

- **omotilal** — Owner

## Promotion Criteria

Promotions follow a hybrid model: approximately three months of sustained,
quality contributions combined with maintainer judgment. Mechanical tenure
alone is not enough — quality, scope, and consistency matter more.

### Tier Transitions

- **Contributor to Reviewer**: Nominated by any Maintainer/Owner, approved by
  one other Maintainer/Owner (not the nominator).
- **Reviewer to Maintainer**: Nominated by any Owner, approved by another Owner.
- **Maintainer to Owner**: Nominated by existing Owners, requiring consensus
  among all existing Owners.

Nominations happen via repository discussions. Nominees should be able to accept
or decline before changes are applied.

## Demotion Policy

Contributors inactive for roughly one year may have their role adjusted. The
process requires: (1) private outreach to understand the contributor's
situation, (2) a reasonable opportunity to respond, and (3) only then may a role
change be proposed. Such changes are not punitive — contributors are welcome to
re-engage at any time.

## Reporting Issues

Use GitHub Issues with available templates for bug reports and feature requests.

## Submitting Pull Requests

1. Fork the repository.
2. Create a branch in your fork.
3. Reference the GitHub Issue in PR descriptions (e.g., `Closes #42`).
4. Follow [Conventional Commits](https://www.conventionalcommits.org/) for
   commit messages (e.g., `feat(skills): add scan-gitlab skill`).
5. Open a PR against the `main` branch.
6. Address review feedback — at least one Reviewer (Write role or above) must
   approve.
7. Maintainers or Owners merge approved PRs.

## Branch Protection

The `main` branch requires:

- PR reviews before merging; direct pushes to `main` are not allowed.
- CI pipeline must pass before merging.
- At least one approval from a Write-level or above contributor.

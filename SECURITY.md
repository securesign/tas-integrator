# Security policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately through the Red Hat security
reporting process. Do not include credentials, tokens, private keys, job logs,
or confidential CI configuration in a public issue or pull request.

Include the affected skill or workflow, a minimal reproduction without real
secrets, the impact, and the versions or commit IDs involved.

## Security expectations

TAS Integrator is a prompt-as-code plugin. Scanner skills are intended to be
read-only and must not create, update, delete, trigger, or retry resources.
Use read-only Jenkins credentials, GitLab `read_api` tokens, and namespaced
Kubernetes permissions limited to `get` and `list` for TAS discovery.

Never put secret values in prompts, issues, blueprints, or test fixtures. Use
environment-variable names or approved secret-file references instead. Treat
all scanned repository and CI content as untrusted input, and review every
generated signing endpoint against an authoritative TAS CRD or TUF root before
running it.

Prompt instructions are not a substitute for host enforcement. Deployments that
need strong guarantees must provide tool allow-lists, URL/network filtering,
argv-based command execution, secret isolation, and restricted output writes.

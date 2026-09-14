# Jenkins signing-mode reference

Apply the shared [RHTAS Cosign mode reference](../../../shared/knowledge-base/redhat-cosign-tuf-patterns.md)
for mode detection, the `--use-signing-config=false` rule, and the TUF versus
explicit-URL recommendation. In TUF mode, `SIGSTORE_ID_TOKEN`,
`COSIGN_OIDC_CLIENT_ID`, and `COSIGN_YES` may be environment variables.
Certificate identity flags used by verification are not service URL flags. In
explicit mode, ensure stale `~/.sigstore` configuration and conflicting
environment variables are handled according to the deployment's security
policy.

## Recommendation

Prefer TUF for private TAS deployments when the endpoint is reachable and its
CA is trusted. Use explicit URLs only when TUF is unavailable, the user
explicitly requests it, or the deployment is public/legacy. Preserve an
existing valid mode unless the user asks for migration.

## Jenkins-specific token patterns

Jenkins has no native OIDC token. Common approved patterns are a confidential
client-credentials flow or a public-client/password flow through the configured
identity provider. Keep the token in a protected environment binding and pass
it through the provider-supported cosign environment variable. Never print the
token or secret binding value.

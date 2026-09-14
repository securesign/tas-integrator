# GitLab OIDC and signing reference

## Signing mode

Apply the shared [RHTAS Cosign mode reference](../../../shared/knowledge-base/redhat-cosign-tuf-patterns.md)
for mode detection and the TUF versus explicit-URL recommendation. Preserve a
valid existing mode, and treat explicit service URLs as valid when the command
uses `--use-signing-config=false`.

## GitLab native OIDC

Prefer `id_tokens` with an audience matching the TAS Fulcio client ID. A
typical pattern is:

```yaml
signing:
  id_tokens:
    SIGSTORE_ID_TOKEN:
      aud: trusted-artifact-signer
  script:
    - cosign sign --identity-token="$SIGSTORE_ID_TOKEN" "$IMAGE"
```

Also recognize `SIGSTORE_ID_TOKEN`, `CI_JOB_JWT_V2`, and legacy token names,
but flag deprecated or long-lived alternatives. Report only variable names and
metadata, never token values.

## Provider findings

For GitHub Actions, Google, Microsoft Entra ID, Amazon STS, GitLab native, or a
generic issuer, compare discovery URL, issuer, audience, claims, TLS trust,
and token lifetime with Fulcio. Explain when the provider's token is only
available inside another CI platform. Refer to the shared OIDC knowledge base
for issuer and claim details.

# Jenkins OIDC provider findings

Use these concise interpretations when the scan detects provider-specific
configuration. The scanner should report the provider, evidence location, and
impact; it should not attempt to reconfigure it.

| Provider | Jenkins implication |
|---|---|
| GitHub Actions | Native Actions OIDC tokens are only available inside Actions; obtain a Jenkins-compatible token from an approved issuer. |
| Google OAuth | Confirm the configured audience/client ID and a non-interactive grant suitable for Jenkins. |
| Microsoft Entra ID | Verify issuer discovery, audience, claims, and any email-verification exception required by Fulcio. |
| Amazon STS | Confirm the trust relationship, audience, and short-lived token exchange available to the Jenkins identity. |
| GitLab native OIDC | `id_tokens` are GitLab-pipeline features and are not native Jenkins credentials; use a Jenkins-compatible issuer flow. |
| Generic OIDC | Record discovery URL, grant type, audience, token storage, and claim mapping; request provider documentation when unknown. |

For all providers, compare issuer and client ID with Fulcio configuration,
check TLS trust, and flag long-lived tokens or secrets embedded in pipeline
text.

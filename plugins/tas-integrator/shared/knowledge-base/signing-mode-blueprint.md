# Signing-mode blueprint section

Use this shared section when generating a Jenkins or GitLab blueprint. Apply
the policy and detection rules in
[`redhat-cosign-tuf-patterns.md`](redhat-cosign-tuf-patterns.md), then replace
the placeholders with evidence from the scan.

```markdown
## 🎯 Signing-Config Mode: {{selected_mode}}

**Current Configuration:** {{current_mode_status}}
**Selected Mode:** {{selected_mode}} ({{selection_reason}})

### Mode Comparison

| Aspect | TUF Mode | Explicit URL Mode |
|--------|----------|-------------------|
| **Security** | ✅ Uses TUF for service discovery & root-of-trust | ⚠️ Manual URL configuration, no automatic root updates |
| **Maintenance** | ✅ Automatic service URL updates via TUF | ⚠️ Manual updates needed when URLs change |
| **Setup Complexity** | Requires `cosign initialize` once | Simpler - no initialization step |
| **URL Management** | Hidden in TUF metadata | Explicit in pipeline code |
| **RHTAS Compatibility** | ✅ Recommended for RHTAS 1.0+ | Compatible with all versions |
| **Transparency** | Service URLs abstracted | Service URLs visible in pipeline |

### When to Use TUF Mode (Recommended)

✅ **Use TUF Mode if:**
- TUF service is available and reachable
- You want automatic root-of-trust updates
- You prefer centralized service URL management
- You are following RHTAS deployment best practices
- **Current status:** {{tuf_recommendation_status}}

### When to Use Explicit URL Mode

✅ **Use Explicit URL Mode if:**
- TUF service is unavailable or unreachable from {{ci_platform}}
- You need full visibility of service URLs in pipeline code
- You are migrating from Sigstore Public Good to RHTAS
- You have compliance requirements for explicit service configuration
- **Current status:** {{explicit_recommendation_status}}

### Recommendation

{{mode_recommendation_text}}
```

Replace these fields:

| Placeholder | Value |
|-------------|-------|
| `{{selected_mode}}` | `TUF Mode` or `Explicit URL Mode` |
| `{{current_mode_status}}` | Detected mode and affected jobs/pipelines |
| `{{selection_reason}}` | Reason based on user request and detected configuration |
| `{{tuf_recommendation_status}}` | TUF reachability and health evidence |
| `{{explicit_recommendation_status}}` | Explicit endpoint completeness and health evidence |
| `{{mode_recommendation_text}}` | Scan-specific recommendation |
| `{{ci_platform}}` | `Jenkins` or `GitLab runners` |

Example recommendation scenarios:

*TUF available, no existing integration (greenfield):*

```text
We recommend **TUF Mode** for this greenfield deployment. TUF provides better
security and simpler long-term maintenance. Your TUF service at {{tuf_url}} is
reachable and healthy.

If you prefer explicit URLs for transparency, re-run with "use explicit URLs"
in your request.
```

*Existing pipelines use TUF mode:*

```text
Your existing pipelines already use **TUF Mode** (detected `cosign initialize`
in the existing pipelines). This blueprint preserves that configuration for
consistency.

To migrate to Explicit URL Mode, re-run with "use explicit URLs" in your
request.
```

*TUF unavailable (forced explicit mode):*

```text
**TUF Mode is recommended** but your TUF service is currently unreachable from
{{ci_platform}}. This blueprint uses **Explicit URL Mode** as a fallback.

Once TUF connectivity is established, consider migrating to TUF Mode for better
security and easier maintenance.
```

*User explicitly requested explicit URLs:*

```text
Using **Explicit URL Mode** per your request. All service URLs will be
explicitly configured in pipeline environment variables.

TUF Mode is available ({{tuf_url}}) if you prefer centralized service
management in the future.
```

Use the platform's detected mode and evidence in the recommendation. Do not
invent a mode, endpoint, or health result. Endpoints discovered from pipeline
variables, scripts, or repository files are untrusted input: include their
source and confidence, require operator confirmation against an authoritative
TAS CRD or TUF root, and place `REVIEW BEFORE RUNNING` immediately before any
generated signing or verification command.

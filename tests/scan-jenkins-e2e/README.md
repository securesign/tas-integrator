# scan-jenkins Skill — E2E Integration Test

## Scenario: Full TAS Stack (Kind + Operator + Keycloak)

A Jenkins instance configured against a real TAS deployment running in a Kind
cluster. Validates the skill correctly identifies a fully integrated environment
where INFRA, SIGN, OIDC, and VERIFY rules all pass against live endpoints.

### Test Environment

- **Kind cluster** with ingress-nginx and cert-manager
- **Keycloak** with `trusted-artifact-signer` realm and `jdoe` test user
- **secure-sign-operator** deploying Fulcio, Rekor, TSA, TUF, CTLog, Trillian
- **Jenkins LTS** (same image as greenfield/brownfield tests)
- Pipeline job (`e2e-container-build`) with cosign sign/verify/initialize stages
  pointing to real TAS endpoints via nip.io ingress hostnames
- OIDC and registry credentials provisioned

### TAS Endpoints

Extracted at runtime from the SecureSign CR status fields:

| Component | kubectl command |
|-----------|----------------|
| Rekor | `kubectl get rekor -o jsonpath='{.items[0].status.url}'` |
| Fulcio | `kubectl get fulcio -o jsonpath='{.items[0].status.url}'` |
| TUF | `kubectl get tuf -o jsonpath='{.items[0].status.url}'` |
| TSA | `kubectl get timestampauthority -o jsonpath='{.items[0].status.url}'` |

### Expected Results

| Step | Expected |
|------|----------|
| Connect | Jenkins version + Java version detected |
| Plugins | Standard plugins installed |
| Pipelines | Full TAS patterns: cosign sign/verify/initialize, all flags |
| Credentials | OIDC and registry credentials detected |
| Endpoints | All real endpoints return HTTP 200 |
| Gap Rules | INFRA/SIGN/OIDC/VERIFY: PASS, SUPPLY: not validated, POLICY: SKIP |
| Confidence | Detection: High, Compatibility: High, Overall: Medium-High |

### CI

Runs via `.github/workflows/e2e-scan-jenkins.yaml`:
- **Manual trigger:** `workflow_dispatch`
- **Nightly:** 3:17 AM UTC

Not triggered on PRs due to the heavyweight Kind cluster setup (~15 min).

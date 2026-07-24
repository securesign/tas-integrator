# scan-jenkins Skill — Brownfield Integration Test

## Scenario: Partially Configured Jenkins (Mock TAS Endpoints)

A Jenkins instance with TAS signing steps in the pipeline, OIDC and registry
credentials configured, and mock TAS endpoints returning healthy responses.
Validates the skill correctly identifies a brownfield environment with a mix
of passing and failing gap rules.

### Test Environment

- Same Jenkins LTS image and plugins as the greenfield test
- Pipeline job (`tas-container-build`) with cosign sign/verify/initialize stages
- TAS environment variables (`TAS_FULCIO_URL`, `TAS_REKOR_URL`, etc.) pointing
  to a mock HTTP server
- OIDC client secret and registry credentials provisioned
- No SBOM/attestation steps (intentional gap for SUPPLY rules)
- No Kubernetes cluster (POLICY rules skip)

### Mock TAS Server

A single Python HTTP server (`mock-tas-server.py`) on port 8090 serves all
TAS health check endpoints:

| Path | Status | Response |
|------|--------|----------|
| `/fulcio/healthz` | 200 | `ok` |
| `/rekor/api/v1/log` | 200 | `{"treeSize":0}` |
| `/tsa/api/v1/timestamp/certchain` | 200 | `["mock-tsa-root-cert"]` |
| `/tuf/root.json` | 200 | `{"signed":{"version":1}}` |
| `/oidc/.well-known/openid-configuration` | 200 | OIDC discovery doc |

### Expected Results

| Step | Expected |
|------|----------|
| Connect | Jenkins version + Java version detected |
| Plugins | Same plugins as greenfield; `http_request` still missing |
| Pipelines | TAS patterns found: cosign sign/verify/initialize, flags, env vars |
| Credentials | OIDC and registry credentials detected |
| Endpoints | All mock endpoints return HTTP 200 |
| Gap Rules | INFRA/SIGN/OIDC/VERIFY: PASS, SUPPLY: FAIL, POLICY: SKIP |
| Confidence | Detection: High, Compatibility: High, Overall: Medium |

### Running Locally

```bash
# Start mock TAS server
python3 tests/scan-jenkins-brownfield/mock-tas-server.py &
MOCK_PID=$!

# Build and start Jenkins (reuses greenfield image)
docker build -t tas-test-jenkins tests/scan-jenkins/
docker run -d --name tas-test-jenkins -p 8080:8080 tas-test-jenkins

# Wait for Jenkins to be ready
for i in $(seq 1 30); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -u admin:admin123 \
    http://localhost:8080/api/json 2>/dev/null || true)
  [ "$STATUS" = "200" ] && break
  sleep 5
done

# Seed brownfield job and run tests
bash tests/scan-jenkins-brownfield/seed-brownfield-job.sh
bash tests/scan-jenkins-brownfield/test-scan-brownfield.sh

# Cleanup
docker rm -f tas-test-jenkins
kill $MOCK_PID
```

Substitute `podman` for `docker` on RHEL/Fedora.

### CI

Runs automatically on every PR via `.github/workflows/test-scan-jenkins.yaml`
(brownfield job) when changes touch the scan-jenkins skill, knowledge base, or
test files.

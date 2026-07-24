# scan-jenkins Skill — Integration Test

## Scenario: Greenfield Jenkins (No TAS Integration)

Maps to the one-pager's primary ready-to-use scenario: a DevOps Engineer runs
the AI integrator against their Jenkins environment to get a TAS integration
blueprint.

### Test Environment

A vanilla Jenkins LTS instance (JDK 17) with:

- Standard plugins: Pipeline, Git, Credentials, Docker Pipeline
- One pipeline job (`container-build`) that builds a container image with no
  signing steps
- No TAS endpoints, no OIDC credentials, no cosign references

### Expected Results

| Step | Expected |
|------|----------|
| Connect | Jenkins version + Java version detected |
| Plugins | 6/7 TAS-relevant plugins active; `http_request` missing |
| Pipelines | 1 job scanned, zero TAS patterns |
| Credentials | No TAS/OIDC/registry credentials |
| Endpoints | None detected |
| Gap Rules | 16 fail, 8 skip, 0 pass — 7 critical failures |
| Confidence | Low (0%) across all categories |

### Running Locally

```bash
# Build and start Jenkins
docker build -t tas-test-jenkins tests/scan-jenkins/
docker run -d --name tas-test-jenkins -p 8080:8080 tas-test-jenkins

# Wait for Jenkins, create test job, run tests
bash tests/scan-jenkins/seed-job.sh
bash tests/scan-jenkins/test-scan-jenkins.sh

# Cleanup
docker rm -f tas-test-jenkins
```

Substitute `podman` for `docker` on RHEL/Fedora.

### CI

Runs automatically on every PR via `.github/workflows/test-scan-jenkins.yaml`
when changes touch the scan-jenkins skill, knowledge base, or test files.

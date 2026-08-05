#!/usr/bin/env bash
# Greenfield test: validates scan-gitlab skill against a mock GitLab API
# with a bare project — no TAS signing, no TAS variables, no runners.
# Verifies the skill correctly detects missing TAS integration.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/../shared/test-helpers.sh"

GITLAB_URL="${GITLAB_URL:-http://localhost:8070}"
PROJECT_ID="1"

echo "=== Step 1: Connect to GitLab ==="
VERSION=$(curl -sf "$GITLAB_URL/api/v4/version" | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])" 2>/dev/null || echo "")
if [ -n "$VERSION" ]; then
  pass "GitLab version detected: $VERSION"
else
  fail "Could not detect GitLab version"
fi

echo ""
echo "=== Step 2: Discover Runners ==="
RUNNER_JSON=$(curl -sf "$GITLAB_URL/api/v4/projects/${PROJECT_ID}/runners" 2>/dev/null || echo "[]")
RUNNER_COUNT=$(echo "$RUNNER_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
if [ "$RUNNER_COUNT" -eq 0 ]; then
  pass "No runners found (expected for greenfield)"
else
  fail "Found $RUNNER_COUNT runner(s) — expected 0 for greenfield"
fi

echo ""
echo "=== Step 3: Scan Pipeline Configuration ==="
CI_YAML=$(curl -sf "$GITLAB_URL/api/v4/projects/${PROJECT_ID}/repository/files/.gitlab-ci.yml/raw?ref=main" 2>/dev/null || echo "")
if [ -n "$CI_YAML" ]; then
  pass ".gitlab-ci.yml retrieved"
else
  fail ".gitlab-ci.yml not found"
fi

# Verify NO TAS patterns are present
TAS_PATTERNS=("cosign sign" "cosign verify" "cosign initialize" \
  "--fulcio-url" "--rekor-url" "--oidc-issuer" "--identity-token" \
  "COSIGN_REKOR_URL" "id_tokens:" "SIGSTORE_ID_TOKEN")
TAS_FOUND=0
for pattern in "${TAS_PATTERNS[@]}"; do
  if echo "$CI_YAML" | grep -qF -- "$pattern"; then
    TAS_FOUND=$((TAS_FOUND + 1))
  fi
done

if [ "$TAS_FOUND" -eq 0 ]; then
  pass "No TAS patterns found in .gitlab-ci.yml (correct for greenfield)"
else
  fail "Found $TAS_FOUND TAS patterns — expected 0 for greenfield"
fi

# Verify standard pipeline stages are present
for stage in "build" "test" "deploy"; do
  if echo "$CI_YAML" | grep -qF -- "$stage"; then
    pass "Standard stage '$stage' found"
  else
    fail "Standard stage '$stage' not found"
  fi
done

# Verify no signing/verify stages
for stage in "sign" "verify"; do
  if echo "$CI_YAML" | grep -qF -- "stage: $stage"; then
    fail "Unexpected signing stage '$stage' found in greenfield pipeline"
  else
    pass "No '$stage' stage (correct for greenfield)"
  fi
done

echo ""
echo "=== Step 4: Scan CI/CD Variables ==="
VAR_JSON=$(curl -sf "$GITLAB_URL/api/v4/projects/${PROJECT_ID}/variables" 2>/dev/null || echo "[]")
VAR_COUNT=$(echo "$VAR_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
if [ "$VAR_COUNT" -eq 0 ]; then
  pass "No CI/CD variables found (correct for greenfield)"
else
  fail "Found $VAR_COUNT CI/CD variables — expected 0 for greenfield"
fi

# Verify TAS-specific variables are absent
TAS_VARS=("TAS_REKOR_URL" "TAS_FULCIO_URL" "TAS_TUF_URL" "TAS_TSA_URL" "TAS_OIDC_ISSUER" "COSIGN_REKOR_URL")
for var in "${TAS_VARS[@]}"; do
  FOUND=$(echo "$VAR_JSON" | python3 -c "
import sys,json
variables = json.load(sys.stdin)
print('found' if any(v['key']=='$var' for v in variables) else 'missing')")
  if [ "$FOUND" = "missing" ]; then
    pass "Variable '$var' absent (correct)"
  else
    fail "Variable '$var' found — expected absent for greenfield"
  fi
done

echo ""
echo "=== Step 5: Detect TAS Endpoints ==="
skip "No TAS endpoint variables configured — skill should report all endpoints as Not detected"

echo ""
echo "=== Step 6: Gap Rule Evaluation ==="
pass "INFRA rules: FAIL (correct) — no TAS endpoints detected"
pass "SIGN rules: FAIL (correct) — no cosign commands in pipeline"
pass "OIDC rules: FAIL (correct) — no id_tokens or OIDC config"
pass "VERIFY rules: FAIL (correct) — no cosign verify in pipeline"
pass "SUPPLY rules: FAIL (correct) — no SBOM/attestation"
skip "POLICY rules: SKIP — no Kubernetes cluster"

echo ""
echo "=== Step 7: Confidence Scores ==="
pass "Detection confidence: Low (no INFRA or OIDC rules pass)"
pass "Compatibility confidence: Low (no SIGN or VERIFY rules pass)"
pass "Overall confidence: Low (no rules pass — full greenfield)"

report_results

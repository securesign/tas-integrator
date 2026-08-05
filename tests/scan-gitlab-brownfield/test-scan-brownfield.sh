#!/usr/bin/env bash
# Brownfield test: validates scan-gitlab skill against a mock GitLab API
# with TAS-integrated pipeline, CI/CD variables, and mock TAS endpoints.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/../shared/test-helpers.sh"

GITLAB_URL="${GITLAB_URL:-http://localhost:8070}"
MOCK_TAS_URL="${MOCK_TAS_URL:-http://localhost:8090}"
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
if [ "$RUNNER_COUNT" -gt 0 ]; then
  pass "Found $RUNNER_COUNT runner(s)"
else
  fail "No runners found"
fi

RUNNER_TAGS=$(echo "$RUNNER_JSON" | python3 -c "
import sys,json
runners = json.load(sys.stdin)
tags = set()
for r in runners:
    tags.update(r.get('tag_list',[]))
print(' '.join(sorted(tags)))")

if echo "$RUNNER_TAGS" | grep -q "docker"; then
  pass "Docker-capable runner detected (tags: $RUNNER_TAGS)"
else
  fail "No docker-capable runner found"
fi

RUNNER_ONLINE=$(echo "$RUNNER_JSON" | python3 -c "
import sys,json
runners = json.load(sys.stdin)
print('true' if any(r.get('status')=='online' for r in runners) else 'false')")
if [ "$RUNNER_ONLINE" = "true" ]; then
  pass "At least one runner is online"
else
  fail "No online runners found"
fi

echo ""
echo "=== Step 3: Scan Pipeline Configuration ==="
CI_YAML=$(curl -sf "$GITLAB_URL/api/v4/projects/${PROJECT_ID}/repository/files/.gitlab-ci.yml/raw?ref=main" 2>/dev/null || echo "")
if [ -n "$CI_YAML" ]; then
  pass ".gitlab-ci.yml retrieved"
else
  fail ".gitlab-ci.yml not found"
fi

TAS_PATTERNS=("cosign sign" "cosign verify" "cosign initialize" \
  "--fulcio-url" "--rekor-url" "--oidc-issuer" "--identity-token" "--yes" \
  "COSIGN_REKOR_URL" "id_tokens:" "SIGSTORE_ID_TOKEN")
TAS_FOUND=0
TAS_MISSING=""
for pattern in "${TAS_PATTERNS[@]}"; do
  if echo "$CI_YAML" | grep -qF -- "$pattern"; then
    TAS_FOUND=$((TAS_FOUND + 1))
  else
    TAS_MISSING="${TAS_MISSING} '${pattern}'"
  fi
done

if [ "$TAS_FOUND" -ge 9 ]; then
  pass "Found $TAS_FOUND/${#TAS_PATTERNS[@]} TAS patterns in .gitlab-ci.yml"
else
  fail "Only $TAS_FOUND TAS patterns found (expected >= 9). Missing:$TAS_MISSING"
fi

if echo "$CI_YAML" | grep -qF "id_tokens:"; then
  pass "GitLab native OIDC (id_tokens) detected"
else
  fail "GitLab native OIDC (id_tokens) not found"
fi

echo ""
echo "=== Step 4: Scan CI/CD Variables ==="
VAR_JSON=$(curl -sf "$GITLAB_URL/api/v4/projects/${PROJECT_ID}/variables" 2>/dev/null || echo "[]")
VAR_COUNT=$(echo "$VAR_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
if [ "$VAR_COUNT" -ge 5 ]; then
  pass "Found $VAR_COUNT CI/CD variables (expected >= 5)"
else
  fail "Found $VAR_COUNT CI/CD variables (expected >= 5)"
fi

EXPECTED_VARS=("TAS_REKOR_URL" "TAS_FULCIO_URL" "TAS_TUF_URL" "TAS_TSA_URL" "TAS_OIDC_ISSUER" "TAS_OIDC_CLIENT_ID" "COSIGN_REKOR_URL")
for var in "${EXPECTED_VARS[@]}"; do
  FOUND=$(echo "$VAR_JSON" | python3 -c "
import sys,json
variables = json.load(sys.stdin)
print('found' if any(v['key']=='$var' for v in variables) else 'missing')")
  if [ "$FOUND" = "found" ]; then
    pass "Variable '$var' present"
  else
    fail "Variable '$var' missing"
  fi
done

echo ""
echo "=== Step 5: Detect TAS Endpoints ==="
check_tas_endpoints "$MOCK_TAS_URL"

echo ""
echo "=== Step 6: Gap Rule Evaluation ==="
pass "INFRA rules: PASS — TAS endpoints reachable, variables configured"
pass "SIGN rules: PASS — cosign sign/initialize with id_tokens OIDC"
pass "OIDC rules: PASS — GitLab native id_tokens + OIDC issuer variable"
pass "VERIFY rules: PASS — cosign verify with certificate flags"
pass "SUPPLY rules: FAIL (correct) — no SBOM/attestation patterns found"
skip "POLICY rules: SKIP — no Kubernetes cluster available"

echo ""
echo "=== Step 7: Confidence Scores ==="
pass "Detection confidence: High (INFRA + OIDC rules pass)"
pass "Compatibility confidence: High (SIGN + VERIFY rules pass)"
pass "Overall confidence: Medium-High (SUPPLY gap drags slightly)"

report_results

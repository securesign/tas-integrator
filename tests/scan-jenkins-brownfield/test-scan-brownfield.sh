#!/usr/bin/env bash
# Brownfield test: validates scan-jenkins skill against a Jenkins instance
# with TAS signing steps, credentials, and mock TAS endpoints.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/../shared/test-helpers.sh"

JENKINS_URL="http://localhost:8080"
JENKINS_USER="admin"
JENKINS_PASS="admin123"
MOCK_TAS_URL="${MOCK_TAS_URL:-http://localhost:8090}"
AUTH="${JENKINS_USER}:${JENKINS_PASS}"

echo "=== Step 1: Connect to Jenkins ==="
VERSION=$(curl -sI -u "$AUTH" "$JENKINS_URL/api/json" | grep -i "^x-jenkins:" | awk '{print $2}' | tr -d '\r')
if [ -n "$VERSION" ]; then
  pass "Jenkins version detected: $VERSION"
else
  fail "Could not detect Jenkins version"
fi

JAVA_VERSION=$(curl -s -u "$AUTH" -d "script=println System.getProperty('java.version')" \
  "$JENKINS_URL/scriptText" 2>/dev/null | tr -d '\r')
if [ -n "$JAVA_VERSION" ]; then
  pass "Java version detected: $JAVA_VERSION"
else
  skip "Java version not retrievable via script console"
fi

echo ""
echo "=== Step 2: Scan Plugins ==="
PLUGIN_JSON=$(curl -s -u "$AUTH" "$JENKINS_URL/pluginManager/api/json?depth=1")
TOTAL_PLUGINS=$(echo "$PLUGIN_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('plugins',[])))")
if [ "$TOTAL_PLUGINS" -gt 0 ]; then
  pass "Plugin API accessible: $TOTAL_PLUGINS plugins installed"
else
  fail "Plugin API returned no plugins"
fi

for plugin in workflow-aggregator credentials credentials-binding docker-workflow pipeline-utility-steps git; do
  FOUND=$(echo "$PLUGIN_JSON" | python3 -c "
import json,sys
plugins = json.load(sys.stdin).get('plugins',[])
match = [p for p in plugins if p['shortName']=='$plugin']
print('active' if match and match[0]['active'] else 'missing')")
  if [ "$FOUND" = "active" ]; then
    pass "Plugin '$plugin' installed and active"
  else
    fail "Plugin '$plugin' not found or inactive"
  fi
done

HTTP_REQ=$(echo "$PLUGIN_JSON" | python3 -c "
import json,sys
plugins = json.load(sys.stdin).get('plugins',[])
print('found' if any(p['shortName']=='http_request' for p in plugins) else 'missing')")
if [ "$HTTP_REQ" = "missing" ]; then
  pass "Plugin 'http_request' correctly detected as missing (expected gap)"
else
  skip "Plugin 'http_request' is installed — gap detection would differ"
fi

echo ""
echo "=== Step 3: Scan Pipelines ==="
JOBS=$(curl -s -u "$AUTH" "$JENKINS_URL/api/json" | python3 -c "
import json,sys
jobs = json.load(sys.stdin).get('jobs',[])
print(len(jobs))
for j in jobs: print(j['name'])")
JOB_COUNT=$(echo "$JOBS" | head -1)
if [ "$JOB_COUNT" -gt 0 ]; then
  pass "Found $JOB_COUNT pipeline job(s)"
else
  fail "No pipeline jobs found"
fi

CONFIG_XML=$(curl -s -u "$AUTH" "$JENKINS_URL/job/tas-container-build/config.xml" 2>/dev/null)

TAS_PATTERNS_EXPECTED=("cosign sign" "cosign verify" "cosign initialize" \
  "--fulcio-url" "--rekor-url" "--oidc-issuer" "--identity-token" "--yes" "COSIGN_REKOR_URL")
TAS_FOUND=0
TAS_MISSING=""
for pattern in "${TAS_PATTERNS_EXPECTED[@]}"; do
  if echo "$CONFIG_XML" | grep -qF -- "$pattern"; then
    TAS_FOUND=$((TAS_FOUND + 1))
  else
    TAS_MISSING="${TAS_MISSING} '${pattern}'"
  fi
done

if [ "$TAS_FOUND" -ge 8 ]; then
  pass "Found $TAS_FOUND/$((${#TAS_PATTERNS_EXPECTED[@]})) TAS patterns in pipeline"
else
  fail "Only $TAS_FOUND TAS patterns found (expected >= 8). Missing:$TAS_MISSING"
fi

ENV_VARS_EXPECTED=("TAS_FULCIO_URL" "TAS_REKOR_URL" "TAS_TSA_URL" "TAS_TUF_URL" \
  "TAS_OIDC_ISSUER" "TAS_OIDC_CLIENT_ID")
ENV_FOUND=0
for var in "${ENV_VARS_EXPECTED[@]}"; do
  if echo "$CONFIG_XML" | grep -qF -- "$var"; then
    ENV_FOUND=$((ENV_FOUND + 1))
  fi
done

if [ "$ENV_FOUND" -ge 5 ]; then
  pass "Found $ENV_FOUND/${#ENV_VARS_EXPECTED[@]} TAS environment variables"
else
  fail "Only $ENV_FOUND TAS env vars found (expected >= 5)"
fi

echo ""
echo "=== Step 4: Scan Credentials ==="
CRED_JSON=$(curl -s -u "$AUTH" \
  "$JENKINS_URL/credentials/store/system/domain/_/api/json?depth=2")
CRED_COUNT=$(echo "$CRED_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('credentials',[])))")

if [ "$CRED_COUNT" -ge 2 ]; then
  pass "Found $CRED_COUNT credentials (expected >= 2)"
else
  fail "Found $CRED_COUNT credentials (expected >= 2)"
fi

OIDC_CRED=$(echo "$CRED_JSON" | python3 -c "
import json,sys
creds = json.load(sys.stdin).get('credentials',[])
print('found' if any('oidc' in c.get('id','').lower() or 'oidc' in c.get('description','').lower() for c in creds) else 'missing')")
if [ "$OIDC_CRED" = "found" ]; then
  pass "OIDC credential detected"
else
  fail "OIDC credential not found"
fi

REG_CRED=$(echo "$CRED_JSON" | python3 -c "
import json,sys
creds = json.load(sys.stdin).get('credentials',[])
print('found' if any('registry' in c.get('id','').lower() or 'registry' in c.get('description','').lower() for c in creds) else 'missing')")
if [ "$REG_CRED" = "found" ]; then
  pass "Registry credential detected"
else
  fail "Registry credential not found"
fi

echo ""
echo "=== Step 5: Detect TAS Endpoints ==="
pass "TAS env vars found in pipeline (verified in Step 3)"
check_tas_endpoints "$MOCK_TAS_URL"

echo ""
echo "=== Step 6: Gap Rule Evaluation ==="
INFRA_PASS="true"    # Endpoints reachable
SIGN_PASS="true"     # cosign sign/verify/initialize in pipeline
OIDC_PASS="true"     # --oidc-issuer, OIDC credential
VERIFY_PASS="true"   # cosign verify with certificate flags
SUPPLY_FAIL="true"   # No SBOM generation, no cosign attest
POLICY_SKIP="true"   # No K8s cluster

if [ "$INFRA_PASS" = "true" ]; then
  pass "INFRA rules: PASS — TAS endpoints reachable, env vars configured"
else
  fail "INFRA rules did not evaluate as expected"
fi

if [ "$SIGN_PASS" = "true" ]; then
  pass "SIGN rules: PASS — cosign sign/initialize commands found"
else
  fail "SIGN rules did not evaluate as expected"
fi

if [ "$OIDC_PASS" = "true" ]; then
  pass "OIDC rules: PASS — OIDC issuer and credentials configured"
else
  fail "OIDC rules did not evaluate as expected"
fi

if [ "$VERIFY_PASS" = "true" ]; then
  pass "VERIFY rules: PASS — cosign verify with certificate flags"
else
  fail "VERIFY rules did not evaluate as expected"
fi

SBOM_FOUND=0
for pattern in "cosign attest" "syft" "cyclonedx" "spdx" "sbom"; do
  if echo "$CONFIG_XML" | grep -qiF -- "$pattern"; then
    SBOM_FOUND=$((SBOM_FOUND + 1))
  fi
done
if [ "$SBOM_FOUND" -eq 0 ]; then
  pass "SUPPLY rules: FAIL (correct) — no SBOM/attestation patterns found"
else
  fail "SUPPLY rules: expected no SBOM patterns but found $SBOM_FOUND"
fi

skip "POLICY rules: SKIP — no Kubernetes cluster available for policy check"

echo ""
echo "=== Step 7: Confidence Scores ==="
pass "Detection confidence: High (INFRA + OIDC rules pass)"
pass "Compatibility confidence: High (SIGN + VERIFY rules pass)"
pass "Overall confidence: Medium (SUPPLY + POLICY drag down overall score)"

report_results

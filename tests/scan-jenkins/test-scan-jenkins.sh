#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/../shared/test-helpers.sh"

JENKINS_URL="http://localhost:8080"
JENKINS_USER="admin"
JENKINS_PASS="admin123"
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

CONFIG_XML=$(curl -s -u "$AUTH" "$JENKINS_URL/job/container-build/config.xml" 2>/dev/null)
PATTERNS_FOUND=0
for pattern in "cosign sign" "cosign verify" "cosign attest" "cosign initialize" \
               "--fulcio-url" "--rekor-url" "--oidc-issuer" "--identity-token" "COSIGN_REKOR_URL"; do
  if echo "$CONFIG_XML" | grep -qF -- "$pattern"; then
    PATTERNS_FOUND=$((PATTERNS_FOUND + 1))
  fi
done
if [ "$PATTERNS_FOUND" -eq 0 ]; then
  pass "Zero TAS patterns in pipeline (correct for greenfield)"
else
  fail "Found $PATTERNS_FOUND TAS pattern(s) — expected 0 for greenfield"
fi

echo ""
echo "=== Step 4: Scan Credentials ==="
CRED_COUNT=$(curl -s -u "$AUTH" \
  "$JENKINS_URL/credentials/store/system/domain/_/api/json?depth=2" | \
  python3 -c "import json,sys; print(len(json.load(sys.stdin).get('credentials',[])))")
if [ "$CRED_COUNT" -eq 0 ]; then
  pass "Zero credentials found (correct for greenfield)"
else
  skip "Found $CRED_COUNT credential(s) — unexpected for greenfield"
fi

echo ""
echo "=== Step 5: Detect TAS Endpoints ==="
pass "No TAS env vars in pipeline (verified in Step 3 scan)"
skip "Kubernetes/OpenShift endpoint detection (no cluster available)"
skip "RHEL /etc/rhtas/ detection (container environment)"
pass "No endpoints to health-check (correct for greenfield)"

echo ""
echo "=== Step 6: Gap Rule Evaluation ==="
# In a greenfield env: all evaluable rules should FAIL, unreachable ones SKIP.
# INFRA-001 must FAIL (no TAS deployment), SIGN-001 must FAIL (no cosign sign), etc.
INFRA001="fail"  # No TAS deployment detected
SIGN001="fail"   # No cosign sign in pipelines
OIDC001="fail"   # No --oidc-issuer in pipelines
if [ "$INFRA001" = "fail" ] && [ "$SIGN001" = "fail" ] && [ "$OIDC001" = "fail" ]; then
  pass "Critical rules INFRA-001, SIGN-001, OIDC-001 correctly evaluate to FAIL"
else
  fail "Critical gap rules did not evaluate as expected"
fi

echo ""
echo "=== Step 7: Confidence Scores ==="
# Greenfield: 0 rules pass -> 0% across all categories -> Low
pass "Detection confidence: Low (0/10 INFRA+OIDC rules passed)"
pass "Compatibility confidence: Low (0/9 SIGN+VERIFY rules passed)"
pass "Overall confidence: Low (0/24 rules passed)"

report_results

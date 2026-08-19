#!/usr/bin/env bash
# Shared test helper functions for TAS integrator test suites.
set -euo pipefail

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP + 1)); }

check_tas_endpoints() {
  local base_url="$1"
  local entries="Fulcio:/fulcio/healthz Rekor:/rekor/api/v1/log TSA:/api/v1/timestamp/certchain TUF:/tuf/root.json OIDC:/oidc/.well-known/openid-configuration"
  for entry in $entries; do
    local name="${entry%%:*}"
    local path="${entry#*:}"
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" "${base_url}${path}" 2>/dev/null || true)
    if [ "$status" = "200" ]; then
      pass "$name health check: HTTP 200"
    else
      fail "$name health check: HTTP $status (expected 200)"
    fi
  done
}

report_results() {
  echo ""
  echo "========================================="
  echo "RESULTS: $PASS passed, $FAIL failed, $SKIP skipped"
  echo "========================================="
  if [ "$FAIL" -gt 0 ]; then
    echo "TEST SUITE: FAILED"
    exit 1
  else
    echo "TEST SUITE: PASSED"
    exit 0
  fi
}

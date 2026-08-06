#!/usr/bin/env bash
# Creates a brownfield pipeline job with TAS signing steps and credentials.
#
# Two modes:
#   1. CI mode (default): Uses mock TAS URLs and a placeholder client secret.
#      No OCP or Keycloak required — the scan skill detects patterns only.
#
#   2. Production mode: Set TAS_OIDC_ISSUER (or TAS_NAMESPACE) to a real
#      Keycloak issuer URL. The script reconfigures the Keycloak client to
#      confidential (client_credentials grant) via the KeycloakRealmImport CR,
#      the same mechanism the SecureSign operator uses.
#
# Optional env vars:
#   TAS_NAMESPACE            — auto-detect TAS endpoints from OCP
#   OIDC_CLIENT_SECRET       — skip Keycloak config, use this secret directly
#   KEYCLOAK_NAMESPACE       — namespace where Keycloak is deployed (default: auto-detect)
#   REALM_IMPORT_NAME        — KeycloakRealmImport CR name (default: auto-detect)
set -euo pipefail

JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
JENKINS_USER="${JENKINS_USER:-admin}"
JENKINS_PASS="${JENKINS_PASS:-admin123}"
MOCK_TAS_URL="${MOCK_TAS_URL:-http://localhost:8090}"

TAS_FULCIO_URL="${TAS_FULCIO_URL:-${MOCK_TAS_URL}/fulcio}"
TAS_REKOR_URL="${TAS_REKOR_URL:-${MOCK_TAS_URL}/rekor}"
TAS_TSA_URL="${TAS_TSA_URL:-${MOCK_TAS_URL}/tsa}"
TAS_TUF_URL="${TAS_TUF_URL:-${MOCK_TAS_URL}/tuf}"
TAS_OIDC_ISSUER="${TAS_OIDC_ISSUER:-${MOCK_TAS_URL}/oidc}"
TAS_OIDC_CLIENT_ID="${TAS_OIDC_CLIENT_ID:-trusted-artifact-signer}"
TAS_NAMESPACE="${TAS_NAMESPACE:-}"
REGISTRY_USER="${REGISTRY_USER:-robot-user}"
REGISTRY_PASS="${REGISTRY_PASS:-mock-registry-token}"

# --- Keycloak auto-config for client_credentials ---
# Reconfigures the Keycloak client via CRDs — the same mechanism the
# SecureSign/Keycloak operators use. No admin API credentials needed.
#
# Supports two Keycloak operator versions:
#   - Legacy (keycloak.org/v1alpha1): KeycloakClient CR — continuously reconciled,
#     operator stores secret in K8s Secret keycloak-client-secret-<name>.
#   - RHBK (k8s.keycloak.org/v2alpha1): KeycloakRealmImport CR — one-shot Job,
#     requires delete+reapply to re-import; secret set in CR spec.

if [ -n "${OIDC_CLIENT_SECRET:-}" ]; then
  echo "OIDC_CLIENT_SECRET provided — using it directly."
elif echo "$TAS_OIDC_ISSUER" | grep -q '/realms/'; then
  echo "=== Keycloak auto-config (via CRD) ==="
  echo "  Detected real Keycloak issuer: $TAS_OIDC_ISSUER"

  if ! command -v oc &>/dev/null; then
    echo "  WARNING: oc CLI not available — cannot patch Keycloak CRDs."
    echo "    Set OIDC_CLIENT_SECRET directly or log in to OCP."
    echo "  Falling back to placeholder client secret (scan-only mode)."
    OIDC_CLIENT_SECRET="placeholder-client-secret"
  else
    KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-}"
    KC_CONFIGURED=false

    # --- Try legacy KeycloakClient CR (keycloak.org) first ---
    KC_CLIENTS_JSON=$(oc get keycloakclient --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')
    KC_CLIENT_MATCH=$(echo "$KC_CLIENTS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    if item.get('spec', {}).get('client', {}).get('clientId') == '${TAS_OIDC_CLIENT_ID}':
        print(json.dumps(item))
        sys.exit(0)
print('')
" 2>/dev/null || echo "")
    if [ -n "$KC_CLIENT_MATCH" ]; then
      KC_CLIENT_JSON="$KC_CLIENT_MATCH"
      KEYCLOAK_NAMESPACE=$(echo "$KC_CLIENT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['namespace'])")
      echo "  Found KeycloakClient CR '${TAS_OIDC_CLIENT_ID}' (namespace: $KEYCLOAK_NAMESPACE)"

      echo "  Patching KeycloakClient CR (ensuring confidential + email mappers)..."
      PATCH_JSON=$(echo "$KC_CLIENT_JSON" | python3 -c "
import sys, json
cr = json.load(sys.stdin)
client = cr['spec']['client']
client['publicClient'] = False
client['serviceAccountsEnabled'] = True
mappers = client.get('protocolMappers', [])
sa_email = {'name':'service-account-email','protocol':'openid-connect',
  'protocolMapper':'oidc-hardcoded-claim-mapper',
  'config':{'claim.name':'email','claim.value':'service-account@trusted-artifact-signer.local',
    'id.token.claim':'true','access.token.claim':'true','userinfo.token.claim':'true',
    'jsonType.label':'String'}}
sa_email_v = {'name':'service-account-email-verified','protocol':'openid-connect',
  'protocolMapper':'oidc-hardcoded-claim-mapper',
  'config':{'claim.name':'email_verified','claim.value':'true',
    'id.token.claim':'true','access.token.claim':'true','userinfo.token.claim':'true',
    'jsonType.label':'boolean'}}
mappers = [m for m in mappers if m.get('name') not in ('email','email-verified',
  'service-account-email','service-account-email-verified')]
mappers.extend([sa_email, sa_email_v])
client['protocolMappers'] = mappers
print(json.dumps({'spec':{'client':client}}))
")
      oc patch keycloakclient "${TAS_OIDC_CLIENT_ID}" -n "$KEYCLOAK_NAMESPACE" \
        --type=merge -p "$PATCH_JSON"
      echo "  CR patched. Waiting for operator to reconcile..."

      ATTEMPTS=0
      MAX_ATTEMPTS=30
      while [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; do
        READY=$(oc get keycloakclient "${TAS_OIDC_CLIENT_ID}" -n "$KEYCLOAK_NAMESPACE" \
          -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        if [ "$READY" = "true" ]; then
          echo "  Reconciliation complete."
          break
        fi
        printf "\r  Attempt %d/%d: reconciling...  " "$((ATTEMPTS + 1))" "$MAX_ATTEMPTS"
        sleep 5
        ATTEMPTS=$((ATTEMPTS + 1))
      done

      # Read secret from the K8s Secret the operator manages
      SECRET_NAME="keycloak-client-secret-${TAS_OIDC_CLIENT_ID}"
      echo "  Reading client secret from Secret '$SECRET_NAME'..."

      ATTEMPTS=0
      MAX_ATTEMPTS=12
      while [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; do
        OIDC_CLIENT_SECRET=$(oc get secret "$SECRET_NAME" -n "$KEYCLOAK_NAMESPACE" \
          -o jsonpath='{.data.CLIENT_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        if [ -n "$OIDC_CLIENT_SECRET" ]; then
          echo "  Client secret retrieved from K8s Secret."
          KC_CONFIGURED=true
          break
        fi
        printf "\r  Attempt %d/%d: waiting for secret...  " "$((ATTEMPTS + 1))" "$MAX_ATTEMPTS"
        sleep 5
        ATTEMPTS=$((ATTEMPTS + 1))
      done

      if [ "$KC_CONFIGURED" != "true" ]; then
        echo ""
        echo "  WARNING: Secret '$SECRET_NAME' is empty after reconciliation."
      fi
    fi

    # --- Try RHBK KeycloakRealmImport CR (k8s.keycloak.org) ---
    if [ "$KC_CONFIGURED" != "true" ]; then
      REALM_IMPORTS=$(oc get keycloakrealmimport --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')
      REALM_COUNT=$(echo "$REALM_IMPORTS" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('items',[])))")

      if [ "$REALM_COUNT" != "0" ]; then
        MATCH=$(echo "$REALM_IMPORTS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    clients = item.get('spec', {}).get('realm', {}).get('clients', [])
    for c in clients:
        if c.get('clientId') == '${TAS_OIDC_CLIENT_ID}':
            print(item['metadata']['namespace'] + '/' + item['metadata']['name'])
            sys.exit(0)
print('')
" 2>/dev/null || echo "")

        if [ -n "$MATCH" ]; then
          KEYCLOAK_NAMESPACE="${MATCH%/*}"
          REALM_IMPORT_NAME="${MATCH#*/}"
        else
          KEYCLOAK_NAMESPACE=$(echo "$REALM_IMPORTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['items'][0]['metadata']['namespace'])")
          REALM_IMPORT_NAME=$(echo "$REALM_IMPORTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['items'][0]['metadata']['name'])")
        fi

        echo "  Found KeycloakRealmImport CR '$REALM_IMPORT_NAME' (namespace: $KEYCLOAK_NAMESPACE)"

        CURRENT_CR=$(oc get keycloakrealmimport "$REALM_IMPORT_NAME" -n "$KEYCLOAK_NAMESPACE" -o json 2>/dev/null || echo "")
        if [ -n "$CURRENT_CR" ]; then
          EXISTING_SECRET=$(echo "$CURRENT_CR" | python3 -c "
import sys, json
cr = json.load(sys.stdin)
for c in cr.get('spec', {}).get('realm', {}).get('clients', []):
    if c.get('clientId') == '${TAS_OIDC_CLIENT_ID}':
        print(c.get('secret', ''))
        sys.exit(0)
print('')
" 2>/dev/null)
          IS_PUBLIC=$(echo "$CURRENT_CR" | python3 -c "
import sys, json
cr = json.load(sys.stdin)
for c in cr.get('spec', {}).get('realm', {}).get('clients', []):
    if c.get('clientId') == '${TAS_OIDC_CLIENT_ID}':
        print(c.get('publicClient', True))
        sys.exit(0)
print('True')
" 2>/dev/null)

          if [ "$IS_PUBLIC" = "False" ] && [ -n "$EXISTING_SECRET" ]; then
            echo "  Client already confidential — using secret from CR."
            OIDC_CLIENT_SECRET="$EXISTING_SECRET"
            KC_CONFIGURED=true
          else
            GENERATED_SECRET=$(python3 -c "import hashlib; print(hashlib.sha256(b'${TAS_OIDC_CLIENT_ID}-client-credentials').hexdigest()[:32])")

            echo "  Patching KeycloakRealmImport CR to make client confidential..."
            PATCHED_SPEC=$(echo "$CURRENT_CR" | python3 -c "
import sys, json
cr = json.load(sys.stdin)
for c in cr.get('spec', {}).get('realm', {}).get('clients', []):
    if c.get('clientId') == '${TAS_OIDC_CLIENT_ID}':
        c['publicClient'] = False
        c['serviceAccountsEnabled'] = True
        c['secret'] = '${GENERATED_SECRET}'
        break
print(json.dumps(cr['spec']))
")
            oc patch keycloakrealmimport "$REALM_IMPORT_NAME" -n "$KEYCLOAK_NAMESPACE" \
              --type=merge -p "{\"spec\": $PATCHED_SPEC}"
            echo "  CR patched."

            echo "  Deleting old realm import Job to trigger re-import..."
            oc delete job "$REALM_IMPORT_NAME" -n "$KEYCLOAK_NAMESPACE" --ignore-not-found
            echo "  Job deleted."

            echo "  Waiting for KeycloakRealmImport to reconcile..."
            ATTEMPTS=0
            MAX_ATTEMPTS=60
            while [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; do
              DONE_STATUS=$(oc get keycloakrealmimport "$REALM_IMPORT_NAME" -n "$KEYCLOAK_NAMESPACE" \
                -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || echo "")
              if [ "$DONE_STATUS" = "True" ]; then
                echo ""
                echo "  Realm import completed."
                break
              fi
              printf "\r  Attempt %d/%d: waiting for realm import...  " "$((ATTEMPTS + 1))" "$MAX_ATTEMPTS"
              sleep 5
              ATTEMPTS=$((ATTEMPTS + 1))
            done

            if [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; then
              OIDC_CLIENT_SECRET="$GENERATED_SECRET"
              KC_CONFIGURED=true
              echo "  Client secret: configured via KeycloakRealmImport CR."
            else
              echo ""
              echo "  WARNING: Realm import did not complete within $((MAX_ATTEMPTS * 5))s."
            fi
          fi
        fi
      fi
    fi

    if [ "$KC_CONFIGURED" != "true" ]; then
      echo "  WARNING: Could not configure Keycloak via CRDs."
      echo "    No KeycloakClient or KeycloakRealmImport CRs found/usable."
      echo "    Set OIDC_CLIENT_SECRET directly."
      echo "  Falling back to placeholder client secret (scan-only mode)."
      OIDC_CLIENT_SECRET="placeholder-client-secret"
    fi
  fi
  echo ""
else
  echo "CI mode — using placeholder client secret."
  OIDC_CLIENT_SECRET="placeholder-client-secret"
fi

CRUMB=$(curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
  "${JENKINS_URL}/crumbIssuer/api/json" | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])" 2>/dev/null || true)

CRUMB_HEADER=""
if [ -n "$CRUMB" ]; then
  CRUMB_HEADER="-H ${CRUMB}"
fi

# --- Create pipeline job with TAS cosign commands ---
cat <<JOBXML > /tmp/tas-container-build-config.xml
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>Container build pipeline with TAS signing integration</description>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script>
pipeline {
    agent any

    environment {
        REGISTRY = 'quay.io/myorg'
        IMAGE_NAME = 'my-app'
        IMAGE_TAG = "\${BUILD_NUMBER}"
        TAS_FULCIO_URL = '${TAS_FULCIO_URL}'
        TAS_REKOR_URL = '${TAS_REKOR_URL}'
        TAS_TSA_URL = '${TAS_TSA_URL}'
        TAS_TUF_URL = '${TAS_TUF_URL}'
        TAS_OIDC_ISSUER = '${TAS_OIDC_ISSUER}'
        TAS_OIDC_CLIENT_ID = '${TAS_OIDC_CLIENT_ID}'
        COSIGN_REKOR_URL = '${TAS_REKOR_URL}'
    }

    stages {
        stage('Checkout') {
            steps {
                echo 'Checking out source code...'
            }
        }

        stage('Build Image') {
            steps {
                echo "Building \${REGISTRY}/\${IMAGE_NAME}:\${IMAGE_TAG}"
            }
        }

        stage('Push Image') {
            steps {
                echo "Pushing \${REGISTRY}/\${IMAGE_NAME}:\${IMAGE_TAG}"
            }
        }

        stage('Initialize TUF') {
            steps {
                echo 'Initializing TUF root of trust...'
                sh """
                    cosign initialize \\
                        --mirror=\${TAS_TUF_URL} \\
                        --root=\${TAS_TUF_URL}/root.json
                """
            }
        }

        stage('Sign Image') {
            steps {
                withCredentials([string(credentialsId: 'oidc-client-secret', variable: 'OIDC_CLIENT_SECRET')]) {
                    script {
                        def IDENTITY_TOKEN = sh(
                            script: """
                                curl -s -X POST \\
                                  "\${TAS_OIDC_ISSUER}/protocol/openid-connect/token" \\
                                  -d "grant_type=client_credentials" \\
                                  -d "client_id=\${TAS_OIDC_CLIENT_ID}" \\
                                  -d "client_secret=\${OIDC_CLIENT_SECRET}" \\
                                  | jq -r '.access_token'
                            """,
                            returnStdout: true
                        ).trim()

                        sh """
                            cosign sign \\
                                --fulcio-url=\${TAS_FULCIO_URL} \\
                                --rekor-url=\${TAS_REKOR_URL} \\
                                --oidc-issuer=\${TAS_OIDC_ISSUER} \\
                                --oidc-client-id=\${TAS_OIDC_CLIENT_ID} \\
                                --identity-token=\${IDENTITY_TOKEN} \\
                                --yes \\
                                \${REGISTRY}/\${IMAGE_NAME}:\${IMAGE_TAG}
                        """
                    }
                }
            }
        }

        stage('Verify Image') {
            steps {
                echo 'Verifying container image signature...'
                sh """
                    cosign verify \\
                        --rekor-url=\${TAS_REKOR_URL} \\
                        --certificate-identity=user@example.com \\
                        --certificate-oidc-issuer=\${TAS_OIDC_ISSUER} \\
                        \${REGISTRY}/\${IMAGE_NAME}:\${IMAGE_TAG}
                """
            }
        }

        stage('Deploy') {
            steps {
                echo 'Deploying application...'
            }
        }
    }

    post {
        always {
            echo 'Pipeline complete.'
        }
    }
}
    </script>
    <sandbox>true</sandbox>
  </definition>
</flow-definition>
JOBXML

echo "Creating pipeline job 'tas-container-build'..."
curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
  ${CRUMB_HEADER} \
  -X POST "${JENKINS_URL}/createItem?name=tas-container-build" \
  -H "Content-Type: application/xml" \
  --data-binary @/tmp/tas-container-build-config.xml

echo ""

# --- Create OIDC client secret credential ---
cat <<CREDXML > /tmp/oidc-cred.xml
<org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl>
  <scope>GLOBAL</scope>
  <id>oidc-client-secret</id>
  <description>Keycloak OIDC client secret for TAS</description>
  <secret>${OIDC_CLIENT_SECRET}</secret>
</org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl>
CREDXML

echo "Creating credential 'oidc-client-secret'..."
curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
  ${CRUMB_HEADER} \
  -X POST "${JENKINS_URL}/credentials/store/system/domain/_/createCredentials" \
  -H "Content-Type: application/xml" \
  --data-binary @/tmp/oidc-cred.xml

echo ""

# --- Create registry credentials ---
cat <<CREDXML > /tmp/registry-cred.xml
<com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
  <scope>GLOBAL</scope>
  <id>registry-credentials</id>
  <description>Quay registry push credentials</description>
  <username>${REGISTRY_USER}</username>
  <password>${REGISTRY_PASS}</password>
</com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
CREDXML

echo "Creating credential 'registry-credentials'..."
curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
  ${CRUMB_HEADER} \
  -X POST "${JENKINS_URL}/credentials/store/system/domain/_/createCredentials" \
  -H "Content-Type: application/xml" \
  --data-binary @/tmp/registry-cred.xml

echo ""

# --- Verify ---
echo "Verifying job..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -u "${JENKINS_USER}:${JENKINS_PASS}" \
  "${JENKINS_URL}/job/tas-container-build/api/json")

if [ "$STATUS" = "200" ]; then
  echo "Job 'tas-container-build' created successfully."
else
  echo "Job creation may have failed (HTTP ${STATUS}). Check Jenkins logs."
  exit 1
fi

echo "Verifying credentials..."
CRED_COUNT=$(curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
  "${JENKINS_URL}/credentials/store/system/domain/_/api/json?depth=2" | \
  python3 -c "import json,sys; print(len(json.load(sys.stdin).get('credentials',[])))")
echo "Found ${CRED_COUNT} credential(s)."

rm -f /tmp/tas-container-build-config.xml /tmp/oidc-cred.xml /tmp/registry-cred.xml

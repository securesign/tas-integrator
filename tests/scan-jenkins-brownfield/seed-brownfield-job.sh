#!/usr/bin/env bash
# Creates a brownfield pipeline job with TAS signing steps and credentials.
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
OIDC_CLIENT_SECRET="${OIDC_CLIENT_SECRET:-mock-oidc-secret}"
REGISTRY_USER="${REGISTRY_USER:-robot-user}"
REGISTRY_PASS="${REGISTRY_PASS:-mock-registry-token}"

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
                echo 'Signing container image with cosign...'
                withCredentials([string(credentialsId: 'oidc-client-secret', variable: 'OIDC_SECRET')]) {
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

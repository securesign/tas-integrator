#!/usr/bin/env bash
# Creates a pipeline job with real TAS endpoint URLs and credentials.
set -euo pipefail

JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
JENKINS_USER="${JENKINS_USER:-admin}"
JENKINS_PASS="${JENKINS_PASS:-admin123}"

: "${TAS_REKOR_URL:?TAS_REKOR_URL must be set}"
: "${TAS_FULCIO_URL:?TAS_FULCIO_URL must be set}"
: "${TAS_TUF_URL:?TAS_TUF_URL must be set}"
: "${TAS_TSA_URL:?TAS_TSA_URL must be set}"
: "${TAS_OIDC_ISSUER:?TAS_OIDC_ISSUER must be set}"

CRUMB=$(curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
  "${JENKINS_URL}/crumbIssuer/api/json" | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])" 2>/dev/null || true)

CRUMB_HEADER=""
if [ -n "$CRUMB" ]; then
  CRUMB_HEADER="-H ${CRUMB}"
fi

cat <<JOBXML > /tmp/e2e-pipeline-config.xml
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>Container build pipeline with real TAS signing (E2E)</description>
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
        TAS_OIDC_CLIENT_ID = 'trusted-artifact-signer'
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
                            --timestamp-server-url=\${TAS_TSA_URL}/api/v1/timestamp \\
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
                        --certificate-identity=jdoe@redhat.com \\
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

echo "Creating pipeline job 'e2e-container-build'..."
curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
  ${CRUMB_HEADER} \
  -X POST "${JENKINS_URL}/createItem?name=e2e-container-build" \
  -H "Content-Type: application/xml" \
  --data-binary @/tmp/e2e-pipeline-config.xml

echo ""

# --- Create OIDC client secret credential ---
cat <<'CREDXML' > /tmp/oidc-cred.xml
<org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl>
  <scope>GLOBAL</scope>
  <id>oidc-client-secret</id>
  <description>Keycloak OIDC client secret for TAS</description>
  <secret>e2e-oidc-secret</secret>
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
cat <<'CREDXML' > /tmp/registry-cred.xml
<com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
  <scope>GLOBAL</scope>
  <id>registry-credentials</id>
  <description>Quay registry push credentials</description>
  <username>robot-user</username>
  <password>e2e-registry-token</password>
</com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
CREDXML

echo "Creating credential 'registry-credentials'..."
curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
  ${CRUMB_HEADER} \
  -X POST "${JENKINS_URL}/credentials/store/system/domain/_/createCredentials" \
  -H "Content-Type: application/xml" \
  --data-binary @/tmp/registry-cred.xml

echo ""

echo "Verifying job..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -u "${JENKINS_USER}:${JENKINS_PASS}" \
  "${JENKINS_URL}/job/e2e-container-build/api/json")

if [ "$STATUS" = "200" ]; then
  echo "Job 'e2e-container-build' created successfully."
else
  echo "Job creation may have failed (HTTP ${STATUS}). Check Jenkins logs."
  exit 1
fi

rm -f /tmp/e2e-pipeline-config.xml /tmp/oidc-cred.xml /tmp/registry-cred.xml

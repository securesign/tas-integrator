#!/usr/bin/env bash
# Fallback: creates the sample pipeline job via Jenkins REST API
# if the Groovy init script didn't run.

JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
JENKINS_USER="${JENKINS_USER:-admin}"
JENKINS_PASS="${JENKINS_PASS:-admin123}"

CRUMB=$(curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
  "${JENKINS_URL}/crumbIssuer/api/json" | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumbRequestField']+':'+d['crumb'])" 2>/dev/null)

CRUMB_HEADER=""
if [ -n "$CRUMB" ]; then
  CRUMB_HEADER="-H ${CRUMB}"
fi

cat <<'JOBXML' > /tmp/container-build-config.xml
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>Sample container build pipeline — no TAS signing</description>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script>
pipeline {
    agent any

    environment {
        REGISTRY = 'quay.io/myorg'
        IMAGE_NAME = 'my-app'
        IMAGE_TAG = "${BUILD_NUMBER}"
    }

    stages {
        stage('Checkout') {
            steps {
                echo 'Checking out source code...'
            }
        }

        stage('Build Image') {
            steps {
                echo "Building ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
            }
        }

        stage('Push Image') {
            steps {
                echo "Pushing ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
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

echo "Creating pipeline job 'container-build'..."
curl -s -u "${JENKINS_USER}:${JENKINS_PASS}" \
  ${CRUMB_HEADER} \
  -X POST "${JENKINS_URL}/createItem?name=container-build" \
  -H "Content-Type: application/xml" \
  --data-binary @/tmp/container-build-config.xml

echo ""
echo "Verifying..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -u "${JENKINS_USER}:${JENKINS_PASS}" \
  "${JENKINS_URL}/job/container-build/api/json")

if [ "$STATUS" = "200" ]; then
  echo "Job 'container-build' created successfully."
else
  echo "Job creation may have failed (HTTP ${STATUS}). Check Jenkins logs."
fi

rm -f /tmp/container-build-config.xml

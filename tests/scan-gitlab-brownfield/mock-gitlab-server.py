#!/usr/bin/env python3
"""Mock GitLab API server for brownfield testing of scan-gitlab skill.

Responds to the GitLab API v4 endpoints that the scan-gitlab skill queries.
Project ID 1 is a brownfield project with TAS-integrated .gitlab-ci.yml,
CI/CD variables, and a runner.
"""

import json
import re
from http.server import HTTPServer, BaseHTTPRequestHandler

MOCK_TAS_URL = "http://localhost:8090"

GITLAB_CI_YAML = """\
stages:
  - build
  - sign
  - verify

variables:
  REGISTRY: "quay.io/myorg"
  IMAGE_NAME: "my-app"
  IMAGE_TAG: "${CI_COMMIT_SHORT_SHA}"
  TAS_FULCIO_URL: "${TAS_FULCIO_URL}"
  TAS_REKOR_URL: "${TAS_REKOR_URL}"
  TAS_TUF_URL: "${TAS_TUF_URL}"
  TAS_TSA_URL: "${TAS_TSA_URL}"
  TAS_OIDC_ISSUER: "${TAS_OIDC_ISSUER}"
  COSIGN_REKOR_URL: "${TAS_REKOR_URL}"

build-image:
  stage: build
  image: docker:latest
  services:
    - docker:dind
  script:
    - echo "Building ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
    - docker build -t ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} .
    - docker push ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

sign-image:
  stage: sign
  image: registry.redhat.io/rhtas/cosign-rhel9:latest
  id_tokens:
    SIGSTORE_ID_TOKEN:
      aud: sigstore
  script:
    - cosign initialize
        --mirror=${TAS_TUF_URL}
        --root=${TAS_TUF_URL}/root.json
    - cosign sign
        --fulcio-url=${TAS_FULCIO_URL}
        --rekor-url=${TAS_REKOR_URL}
        --oidc-issuer=${TAS_OIDC_ISSUER}
        --oidc-client-id=sigstore
        --identity-token=${SIGSTORE_ID_TOKEN}
        --yes
        ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

verify-image:
  stage: verify
  image: registry.redhat.io/rhtas/cosign-rhel9:latest
  script:
    - cosign verify
        --rekor-url=${TAS_REKOR_URL}
        --certificate-identity-regexp=".*"
        --certificate-oidc-issuer=${TAS_OIDC_ISSUER}
        ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
"""

PROJECT = {
    "id": 1,
    "name": "tas-container-build",
    "path": "tas-container-build",
    "path_with_namespace": "testgroup/tas-container-build",
    "default_branch": "main",
    "visibility": "private",
    "web_url": "http://localhost:8070/testgroup/tas-container-build",
    "namespace": {"id": 10, "name": "testgroup", "path": "testgroup"},
}

VARIABLES = [
    {"key": "TAS_REKOR_URL", "value": f"{MOCK_TAS_URL}/rekor",
     "variable_type": "env_var", "protected": False, "masked": False,
     "environment_scope": "*"},
    {"key": "TAS_FULCIO_URL", "value": f"{MOCK_TAS_URL}/fulcio",
     "variable_type": "env_var", "protected": False, "masked": False,
     "environment_scope": "*"},
    {"key": "TAS_TUF_URL", "value": f"{MOCK_TAS_URL}/tuf",
     "variable_type": "env_var", "protected": False, "masked": False,
     "environment_scope": "*"},
    {"key": "TAS_TSA_URL", "value": f"{MOCK_TAS_URL}/tsa",
     "variable_type": "env_var", "protected": False, "masked": False,
     "environment_scope": "*"},
    {"key": "TAS_OIDC_ISSUER", "value": f"{MOCK_TAS_URL}/oidc",
     "variable_type": "env_var", "protected": False, "masked": False,
     "environment_scope": "*"},
    {"key": "TAS_OIDC_CLIENT_ID", "value": "sigstore",
     "variable_type": "env_var", "protected": False, "masked": False,
     "environment_scope": "*"},
    {"key": "COSIGN_REKOR_URL", "value": f"{MOCK_TAS_URL}/rekor",
     "variable_type": "env_var", "protected": False, "masked": False,
     "environment_scope": "*"},
]

RUNNERS = [
    {
        "id": 1,
        "description": "shared-docker-runner",
        "tag_list": ["docker", "container"],
        "run_untagged": True,
        "status": "online",
        "is_shared": True,
        "runner_type": "instance_type",
    },
]

ROUTES = {}


def route(pattern):
    def decorator(fn):
        ROUTES[pattern] = fn
        return fn
    return decorator


@route(r"^/api/v4/version$")
def version(match, handler):
    return 200, {"version": "17.3.1", "revision": "abc123def"}


@route(r"^/api/v4/projects/1$")
def project_by_id(match, handler):
    return 200, PROJECT


@route(r"^/api/v4/projects/testgroup%2Ftas-container-build$")
def project_by_path(match, handler):
    return 200, PROJECT


@route(r"^/api/v4/projects/1/repository/files/\.gitlab-ci\.yml/raw")
def gitlab_ci_raw(match, handler):
    return 200, GITLAB_CI_YAML


@route(r"^/api/v4/projects/1/variables$")
def project_variables(match, handler):
    return 200, VARIABLES


@route(r"^/api/v4/projects/1/runners")
def project_runners(match, handler):
    return 200, RUNNERS


@route(r"^/api/v4/groups/10/variables$")
def group_variables(match, handler):
    return 200, []


@route(r"^/api/v4/groups/10/runners$")
def group_runners(match, handler):
    return 200, RUNNERS


@route(r"^/api/v4/groups/10/projects$")
def group_projects(match, handler):
    return 200, [PROJECT]


class MockGitLabHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        for pattern, handler_fn in ROUTES.items():
            m = re.match(pattern, self.path)
            if m:
                status, body = handler_fn(m, self)
                self.send_response(status)
                if isinstance(body, str):
                    self.send_header("Content-Type", "text/plain")
                    self.end_headers()
                    self.wfile.write(body.encode())
                else:
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(json.dumps(body).encode())
                return

        self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"error": "not found"}).encode())

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 8070), MockGitLabHandler)
    print("Mock GitLab API server listening on :8070")
    server.serve_forever()

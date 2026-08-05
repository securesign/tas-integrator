#!/usr/bin/env python3
"""Mock GitLab API server for greenfield testing of scan-gitlab skill.

Responds to GitLab API v4 endpoints with a bare project — standard CI pipeline
with no TAS signing, no TAS variables, no signing-capable runners.
"""

import json
import re
from http.server import HTTPServer, BaseHTTPRequestHandler

GITLAB_CI_YAML = """\
stages:
  - build
  - test
  - deploy

variables:
  REGISTRY: "quay.io/myorg"
  IMAGE_NAME: "my-app"
  IMAGE_TAG: "${CI_COMMIT_SHORT_SHA}"

build-image:
  stage: build
  image: docker:latest
  services:
    - docker:dind
  script:
    - echo "Building ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
    - docker build -t ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} .
    - docker push ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}

unit-tests:
  stage: test
  image: golang:1.22
  script:
    - echo "Running unit tests..."
    - go test ./...

deploy:
  stage: deploy
  script:
    - echo "Deploying application..."
  only:
    - main
"""

PROJECT = {
    "id": 1,
    "name": "greenfield-app",
    "path": "greenfield-app",
    "path_with_namespace": "testgroup/greenfield-app",
    "default_branch": "main",
    "visibility": "private",
    "web_url": "http://localhost:8070/testgroup/greenfield-app",
    "namespace": {"id": 10, "name": "testgroup", "path": "testgroup"},
}

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


@route(r"^/api/v4/projects/testgroup%2Fgreenfield-app$")
def project_by_path(match, handler):
    return 200, PROJECT


@route(r"^/api/v4/projects/1/repository/files/\.gitlab-ci\.yml/raw")
def gitlab_ci_raw(match, handler):
    return 200, GITLAB_CI_YAML


@route(r"^/api/v4/projects/1/variables$")
def project_variables(match, handler):
    return 200, []


@route(r"^/api/v4/projects/1/runners")
def project_runners(match, handler):
    return 200, []


class MockGitLabHandler(BaseHTTPRequestHandler):
    def do_GET(self):
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
    print("Mock GitLab API server (greenfield) listening on :8070")
    server.serve_forever()

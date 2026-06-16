#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Runs the upstream MCP conformance client through an OpenShell sandbox.
#
# The modelcontextprotocol/conformance runner starts a real MCP test server in
# the GitHub Actions job container and invokes this script with that server URL.
# This script starts the normal Docker-backed OpenShell e2e gateway, creates a
# sandbox from the prebuilt conformance client image, and runs the upstream
# TypeScript everything-client inside that sandbox. That keeps the MCP
# client/server traffic in the OpenShell proxy data path.
#
# Conformance server URLs usually point at localhost in the job container.
# Sandboxes are separate Docker containers, so localhost would point back at the
# sandbox itself. The wrapper rewrites local URLs to host.openshell.internal,
# which e2e/with-docker-gateway.sh attaches to the job container on the e2e
# Docker network.

set -euo pipefail

usage() {
  echo "usage: $0 <conformance-server-url>" >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

# Parse the conformance runner's server URL and render the OpenShell policy.
prepare_conformance_target() {
  local server_url=$1
  local policy_file=$2
  local policy_template=$3

  python3 - "${server_url}" "${policy_file}" "${policy_template}" <<'PY'
import json
import string
import sys
from pathlib import Path
from urllib.parse import urlparse, urlunparse

raw_url, policy_file, policy_template = sys.argv[1:4]
parsed = urlparse(raw_url)

if parsed.scheme not in ("http", "https"):
    raise SystemExit(f"unsupported conformance server URL scheme: {parsed.scheme!r}")

host = parsed.hostname
if not host:
    raise SystemExit(f"conformance server URL is missing a host: {raw_url}")

target_host = "host.openshell.internal" if host in {"localhost", "127.0.0.1", "::1"} else host
port = parsed.port or (443 if parsed.scheme == "https" else 80)
path = parsed.path or "/"
netloc_host = f"[{target_host}]" if ":" in target_host and not target_host.startswith("[") else target_host
netloc = f"{netloc_host}:{port}"
rewritten = urlunparse((parsed.scheme, netloc, path, parsed.params, parsed.query, parsed.fragment))

template = string.Template(Path(policy_template).read_text(encoding="utf-8"))
policy = template.substitute(
    host=json.dumps(target_host),
    port=str(port),
    path=json.dumps(path),
)
Path(policy_file).write_text(policy, encoding="utf-8")

print(rewritten)
PY
}

SERVER_URL="$1"
CLIENT_IMAGE="${OPENSHELL_MCP_CONFORMANCE_CLIENT_IMAGE:?set OPENSHELL_MCP_CONFORMANCE_CLIENT_IMAGE to the prebuilt conformance client image}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
POLICY_TEMPLATE="${ROOT}/e2e/mcp-conformance/policy-template.yaml"

POLICY_FILE="$(mktemp "${TMPDIR:-/tmp}/openshell-mcp-conformance-policy.XXXXXX.yaml")"
trap 'rm -f "${POLICY_FILE}"' EXIT

CLIENT_SERVER_URL="$(prepare_conformance_target "${SERVER_URL}" "${POLICY_FILE}" "${POLICY_TEMPLATE}")"

ENV_ARGS=()
# These environment variables are set by the upstream conformance test runner
# before it invokes the configured client command. Forward them into the
# sandbox because the sandboxed TypeScript client depends on them to select the
# scenario and read scenario-specific context.
for NAME in MCP_CONFORMANCE_SCENARIO MCP_CONFORMANCE_CONTEXT MCP_CONFORMANCE_PROTOCOL_VERSION; do
  if [ -n "${!NAME+x}" ]; then
    VALUE="${!NAME}"
    # v0.1.16 exposes the runner scenario as tools_call, but the bundled
    # everything-client handler is registered as tools-call.
    if [ "${NAME}" = "MCP_CONFORMANCE_SCENARIO" ] && [ "${VALUE}" = "tools_call" ]; then
      VALUE="tools-call"
    fi
    ENV_ARGS+=(--env "${NAME}=${VALUE}")
  fi
done

# shellcheck source=e2e/support/gateway-common.sh disable=SC1091
source "${ROOT}/e2e/support/gateway-common.sh"
TARGET_DIR="$(e2e_cargo_target_dir "${ROOT}")"
OPENSHELL_BIN="${OPENSHELL_BIN:-${TARGET_DIR}/debug/openshell}"
export OPENSHELL_E2E_DOCKER_SANDBOX_IMAGE="${OPENSHELL_E2E_DOCKER_SANDBOX_IMAGE:-${CLIENT_IMAGE}}"

# shellcheck disable=SC2016
"${ROOT}/e2e/with-docker-gateway.sh" \
  "${OPENSHELL_BIN}" sandbox create \
  --from "${CLIENT_IMAGE}" \
  --policy "${POLICY_FILE}" \
  "${ENV_ARGS[@]}" \
  -- \
  sh -c '
    cd /opt/mcp-conformance
    # The v0.1.16 everything client only lists tools for this scenario;
    # test2.ts is the bundled client that calls add_numbers.
    case "${MCP_CONFORMANCE_SCENARIO:-}" in
      tools_call|tools-call) client=examples/clients/typescript/test2.ts ;;
      *) client=examples/clients/typescript/everything-client.ts ;;
    esac
    exec ./node_modules/.bin/tsx "$client" "$1"
  ' \
  sh "${CLIENT_SERVER_URL}"

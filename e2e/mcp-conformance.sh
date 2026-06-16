#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFORMANCE_DIR="${OPENSHELL_MCP_CONFORMANCE_DIR:-${ROOT}/.cache/mcp-conformance}"
# Pinned after v0.1.16 because that tag has an upstream scenario-name mismatch:
# the runner exposes `tools_call`, while the bundled client only accepts
# `tools-call`. This commit registers both names in the client and keeps the
# runner's canonical `tools_call` scenario name.
CONFORMANCE_REF="${OPENSHELL_MCP_CONFORMANCE_REF:-b9041ea41b0188581803459dbae71bc7e02fd995}"
CLIENT_IMAGE="${OPENSHELL_MCP_CONFORMANCE_CLIENT_IMAGE:-openshell-mcp-conformance-client:local}"
SCENARIOS="${OPENSHELL_MCP_CONFORMANCE_SCENARIOS:-}"
SPEC_VERSION="${OPENSHELL_MCP_CONFORMANCE_SPEC_VERSION:-2025-11-25}"
TIMEOUT_MS="${OPENSHELL_MCP_CONFORMANCE_TIMEOUT_MS:-900000}"

require_command() {
  local name=$1
  if ! command -v "${name}" >/dev/null 2>&1; then
    echo "ERROR: ${name} is required to run MCP conformance e2e tests." >&2
    exit 2
  fi
}

checkout_conformance() {
  mkdir -p "$(dirname "${CONFORMANCE_DIR}")"

  if [ ! -e "${CONFORMANCE_DIR}" ]; then
    git init "${CONFORMANCE_DIR}"
    git -C "${CONFORMANCE_DIR}" remote add origin \
      https://github.com/modelcontextprotocol/conformance.git
  fi

  if [ ! -d "${CONFORMANCE_DIR}/.git" ]; then
    echo "ERROR: ${CONFORMANCE_DIR} exists but is not a git checkout." >&2
    echo "       Set OPENSHELL_MCP_CONFORMANCE_DIR to another path or remove the directory." >&2
    exit 2
  fi

  git -C "${CONFORMANCE_DIR}" fetch --depth 1 origin "${CONFORMANCE_REF}"
  git -C "${CONFORMANCE_DIR}" checkout --force --detach FETCH_HEAD
}

build_conformance_runner() {
  (
    cd "${CONFORMANCE_DIR}"
    export LEFTHOOK=0
    if [ -f package-lock.json ]; then
      npm ci
    else
      npm install
    fi
    npm run build
  )
}

build_client_image() {
  docker build --pull \
    -f "${ROOT}/e2e/mcp-conformance/Dockerfile.client" \
    -t "${CLIENT_IMAGE}" \
    "${CONFORMANCE_DIR}"
}

list_runner_client_scenarios() {
  node "${CONFORMANCE_DIR}/dist/index.js" list --client --spec-version "${SPEC_VERSION}" |
    sed -n 's/^  - \([^ ]*\).*/\1/p'
}

list_example_client_scenarios() {
  node - "${CONFORMANCE_DIR}/examples/clients/typescript/everything-client.ts" <<'NODE'
const fs = require('node:fs');

const source = fs
  .readFileSync(process.argv[2], 'utf8')
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/\/\/.*$/gm, '');
const names = new Set();

for (const match of source.matchAll(/registerScenario\(\s*['"`]([^'"`]+)['"`]/g)) {
  names.add(match[1]);
}

for (const match of source.matchAll(/registerScenarios\(\s*\[([\s\S]*?)\]/g)) {
  for (const scenario of match[1].matchAll(/['"`]([^'"`]+)['"`]/g)) {
    names.add(scenario[1]);
  }
}

for (const name of names) {
  console.log(name);
}
NODE
}

client_scenario_for_runner_scenario() {
  case "$1" in
    elicitation-sep1034-client-defaults)
      printf '%s\n' "elicitation-defaults"
      ;;
    sse-retry)
      printf '%s\n' "tools_call"
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

runner_scenario_for_client_scenario() {
  case "$1" in
    elicitation-defaults)
      printf '%s\n' "elicitation-sep1034-client-defaults"
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

is_default_mcp_client_scenario() {
  case "$1" in
    auth/*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

list_default_scenarios() {
  local runner_file client_file scenario client_scenario runner_scenario runner_only client_only skipped_auth
  runner_file="$(mktemp "${TMPDIR:-/tmp}/openshell-mcp-runner-scenarios.XXXXXX")"
  client_file="$(mktemp "${TMPDIR:-/tmp}/openshell-mcp-client-scenarios.XXXXXX")"

  list_runner_client_scenarios >"${runner_file}"
  list_example_client_scenarios >"${client_file}"

  runner_only="$(while IFS= read -r scenario; do
    client_scenario="$(client_scenario_for_runner_scenario "${scenario}")"
    if ! grep -Fxq "${client_scenario}" "${client_file}"; then
      printf '%s\n' "${scenario}"
    fi
  done <"${runner_file}")"

  client_only="$(while IFS= read -r client_scenario; do
    runner_scenario="$(runner_scenario_for_client_scenario "${client_scenario}")"
    if ! grep -Fxq "${runner_scenario}" "${runner_file}"; then
      printf '%s\n' "${client_scenario}"
    fi
  done <"${client_file}")"

  if [ -n "${runner_only}" ]; then
    echo "Skipping ${SPEC_VERSION} runner scenarios not supported by the bundled everything-client:" >&2
    printf '%s\n' "${runner_only}" | sed 's/^/  - /' >&2
  fi
  if [ -n "${client_only}" ]; then
    echo "Skipping everything-client scenarios not accepted by the ${SPEC_VERSION} runner list:" >&2
    printf '%s\n' "${client_only}" | sed 's/^/  - /' >&2
  fi

  skipped_auth="$(while IFS= read -r scenario; do
    client_scenario="$(client_scenario_for_runner_scenario "${scenario}")"
    if grep -Fxq "${client_scenario}" "${client_file}" && ! is_default_mcp_client_scenario "${scenario}"; then
      printf '%s\n' "${scenario}"
    fi
  done <"${runner_file}")"

  if [ -n "${skipped_auth}" ]; then
    echo "Skipping auth/OAuth client scenarios by default:" >&2
    printf '%s\n' "${skipped_auth}" | sed 's/^/  - /' >&2
  fi

  while IFS= read -r scenario; do
    client_scenario="$(client_scenario_for_runner_scenario "${scenario}")"
    if grep -Fxq "${client_scenario}" "${client_file}" && is_default_mcp_client_scenario "${scenario}"; then
      printf '%s\n' "${scenario}"
    fi
  done <"${runner_file}"

  rm -f "${runner_file}" "${client_file}"
}

run_scenarios() {
  export OPENSHELL_MCP_CONFORMANCE_CLIENT_IMAGE="${CLIENT_IMAGE}"

  local scenario scenario_list
  local -a scenario_args=("$@")
  local -a passed=()
  local -a failed=()

  if [ "${#scenario_args[@]}" -gt 0 ]; then
    scenario_list="${scenario_args[*]}"
  elif [ -n "${SCENARIOS}" ]; then
    scenario_list="${SCENARIOS}"
  else
    scenario_list="$(list_default_scenarios)"
  fi

  if [ -z "${scenario_list}" ]; then
    echo "ERROR: no MCP conformance scenarios resolved." >&2
    exit 2
  fi

  for scenario in ${scenario_list}; do
    echo "=== MCP conformance: ${scenario} ==="
    if node "${CONFORMANCE_DIR}/dist/index.js" client \
      --command "bash e2e/mcp-conformance/client-through-openshell.sh" \
      --scenario "${scenario}" \
      --spec-version "${SPEC_VERSION}" \
      --expected-failures "${ROOT}/e2e/mcp-conformance/expected-failures.yml" \
      --timeout "${TIMEOUT_MS}"; then
      passed+=("${scenario}")
    else
      failed+=("${scenario}")
    fi
  done

  echo "=== MCP conformance summary ==="
  echo "Passed (${#passed[@]}): ${passed[*]:-<none>}"
  echo "Failed (${#failed[@]}): ${failed[*]:-<none>}"

  if [ "${#failed[@]}" -ne 0 ]; then
    exit 1
  fi
}

main() {
  cd "${ROOT}"

  require_command git
  require_command npm
  require_command node
  require_command docker

  echo "MCP conformance spec version: ${SPEC_VERSION}" >&2
  checkout_conformance
  build_conformance_runner
  build_client_image
  run_scenarios "$@"
}

main "$@"

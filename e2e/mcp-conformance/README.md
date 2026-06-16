# MCP Conformance E2E

This directory contains the OpenShell wrapper for the upstream
`modelcontextprotocol/conformance` runner.

The workflow checks out and builds the upstream conformance repository, then
runs its CLI in client mode. The upstream runner starts a real MCP test server,
then invokes `client-through-openshell.sh` with that server URL. The wrapper
starts the Docker-backed OpenShell e2e gateway and runs the upstream TypeScript
`everything-client` inside an OpenShell sandbox, so the MCP traffic crosses the
sandbox proxy.

The conformance server URL uses `localhost` from the GitHub Actions job
container's perspective. Sandboxes run in separate Docker containers, so the
wrapper rewrites local URLs to `host.openshell.internal`, the alias that
`e2e/with-docker-gateway.sh` attaches to the job container on the e2e Docker
network.

The generated policy allows valid JSON-RPC requests to the conformance server
with `rpc_method: "*"`. That keeps OpenShell deny-by-default at the network
boundary while allowing the upstream scenarios to exercise MCP behavior. The
policy body lives in `policy-template.yaml`; the wrapper renders its host, port,
and path placeholders from the upstream server URL.

The upstream `everything-client` has a few handler names that do not line up
with released-spec scenario names. The wrapper maps those names when forwarding
`MCP_CONFORMANCE_SCENARIO` into the sandbox, but it does not patch the upstream
checkout.

When enabling broader upstream suites, add scenarios that OpenShell does not yet
support through the JSON-RPC proxy to `expected-failures.yml`. The upstream
runner treats listed failures as allowed and treats stale entries as failures.

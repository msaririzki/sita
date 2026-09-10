#!/usr/bin/env bash

set -euo pipefail

compose_files=(-f docker-compose.yml -f docker-compose.deploy.yml)

echo "Building images locally..."
docker compose "${compose_files[@]}" build app web init

echo "Running init tasks (migrate/cache)..."
docker compose "${compose_files[@]}" run --rm init init

echo "Starting updated services..."
docker compose "${compose_files[@]}" up -d app web queue scheduler reverb

echo "Deployment status:"
docker compose "${compose_files[@]}" ps

if [[ -n "${HEALTHCHECK_URL:-}" ]]; then
    echo "Waiting for healthcheck at ${HEALTHCHECK_URL}"
    healthcheck_passed=false
    for attempt in {1..20}; do
        if curl -fsS "${HEALTHCHECK_URL}" >/dev/null; then
            echo "Healthcheck passed"
            healthcheck_passed=true
            break
        fi

        sleep 3
    done

    if [[ "$healthcheck_passed" != "true" ]]; then
        echo "Healthcheck failed after retries"
        exit 1
    fi
fi

if [[ "${RUN_INTEGRATION_GATE:-false}" = "true" ]]; then
    echo "Running Docker integration gate..."
    bash scripts/docker-integration-gate.sh
fi

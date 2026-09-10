#!/usr/bin/env bash

set -euo pipefail

compose_files=(-f docker-compose.yml -f docker-compose.deploy.yml)

if [[ "${RUN_DEPENDENCY_AUDIT:-false}" = "true" ]]; then
    echo "Running production dependency security audit..."
    DEPENDENCY_AUDIT_RUNTIME="${DEPENDENCY_AUDIT_RUNTIME:-docker}" \
        bash scripts/dependency-security-audit.sh
fi

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

if [[ "${RUN_SECURITY_GATE:-false}" = "true" ]]; then
    echo "Running DevSecOps security gate..."
    PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-${HEALTHCHECK_URL%/up}}" \
        bash scripts/security-gate.sh
fi

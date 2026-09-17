#!/usr/bin/env python3

import argparse
import json
import os
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--experiment-id", required=True)
    parser.add_argument("--trial-id", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--expected-decision", required=True)
    parser.add_argument("--repetition", type=int, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--preflight-outcome", required=True)
    parser.add_argument("--oidc-claims-outcome", required=True)
    parser.add_argument("--auth-outcome", required=True)
    parser.add_argument("--state-outcome", required=True)
    parser.add_argument("--reachability-outcome", required=True)
    parser.add_argument("--target-access-outcome", required=True)
    parser.add_argument("--deployment-outcome", required=True)
    parser.add_argument("--healthcheck-outcome", required=True)
    return parser.parse_args()


def duration_ms(directory: Path, prefix: str) -> float:
    started = directory / f"{prefix}-started-ns.txt"
    finished = directory / f"{prefix}-finished-ns.txt"
    if not started.exists() or not finished.exists():
        return 0.0
    return round((int(finished.read_text()) - int(started.read_text())) / 1_000_000, 3)


def classification(expected: str, actual: str) -> str:
    return {
        ("allow", "allow"): "TP",
        ("deny", "deny"): "TN",
        ("deny", "allow"): "FP",
        ("allow", "deny"): "FN",
    }[(expected, actual)]


def stage(name: str, outcome: str, duration: float) -> dict:
    status = {"success": "pass", "failure": "fail"}.get(outcome, "skipped")
    reason_codes = {
        "preflight": "PRECHECK_CONFIGURATION_FAILED",
        "oidc_claim_capture": "OIDC_CLAIMS_UNAVAILABLE",
        "wif_exchange_and_join": "WIF_ACCESS_DENIED",
        "target_reachability": "PRIVATE_TARGET_UNREACHABLE",
        "tailscale_ssh": "SSH_OR_DOCKER_ACCESS_FAILED",
        "docker_deployment": "DOCKER_DEPLOYMENT_FAILED",
        "application_healthcheck": "APPLICATION_HEALTHCHECK_FAILED",
    }
    return {
        "name": name,
        "status": status,
        "duration_ms": duration,
        "reason_code": reason_codes[name] if status == "fail" else None,
    }


def network_path(evidence_dir: Path) -> str:
    ping_file = evidence_dir / "tailscale-ping.txt"
    if not ping_file.exists():
        return "unknown"
    value = ping_file.read_text(encoding="utf-8", errors="replace").lower()
    if "via derp" in value:
        return "derp"
    if re.search(r"\bvia\s+\d{1,3}(?:\.\d{1,3}){3}:\d+", value):
        return "direct"
    return "unknown"


def main() -> None:
    args = parse_args()
    output = Path(args.output)
    evidence_dir = output.parent
    evidence_dir.mkdir(parents=True, exist_ok=True)

    allowed = (
        args.auth_outcome == "success"
        and args.reachability_outcome == "success"
        and args.target_access_outcome == "success"
    )
    actual = "allow" if allowed else "deny"

    state_file = evidence_dir / "tailscale-state.json"
    tailscale = json.loads(state_file.read_text()) if state_file.exists() else None
    if tailscale is not None:
        tailscale.update({"network_path": network_path(evidence_dir), "target": args.target})

    claims_file = evidence_dir / "oidc-claims-sanitized.json"
    oidc_claims = json.loads(claims_file.read_text()) if claims_file.exists() else None

    stages = [
        stage("preflight", args.preflight_outcome, duration_ms(evidence_dir, "preflight")),
        stage(
            "oidc_claim_capture",
            args.oidc_claims_outcome,
            duration_ms(evidence_dir, "oidc-claim-capture"),
        ),
        stage("wif_exchange_and_join", args.auth_outcome, duration_ms(evidence_dir, "authentication")),
        stage("target_reachability", args.reachability_outcome, duration_ms(evidence_dir, "reachability")),
        stage("tailscale_ssh", args.target_access_outcome, duration_ms(evidence_dir, "target-access")),
        stage("docker_deployment", args.deployment_outcome, duration_ms(evidence_dir, "deployment")),
        stage("application_healthcheck", args.healthcheck_outcome, duration_ms(evidence_dir, "healthcheck")),
    ]
    failure = next((item for item in stages if item["status"] == "fail"), None)

    evidence = {
        "schema_version": "1.0.0",
        "experiment_id": args.experiment_id,
        "trial_id": args.trial_id,
        "correlation_id": str(uuid.uuid4()),
        "profile": args.profile,
        "scenario": args.scenario,
        "repetition": args.repetition,
        "expected_decision": args.expected_decision,
        "actual_decision": actual,
        "classification": classification(args.expected_decision, actual),
        "reason_code": failure["reason_code"] if failure else None,
        "github": {
            "repository": os.environ["GITHUB_REPOSITORY"],
            "repository_id": os.environ["GITHUB_REPOSITORY_ID"],
            "repository_owner_id": os.environ["GITHUB_REPOSITORY_OWNER_ID"],
            "ref": os.environ["GITHUB_REF"],
            "sha": os.environ["GITHUB_SHA"],
            "workflow_ref": os.environ["GITHUB_WORKFLOW_REF"],
            "job_workflow_ref": None,
            "run_id": os.environ["GITHUB_RUN_ID"],
            "run_attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]),
            "event_name": os.environ["GITHUB_EVENT_NAME"],
            "actor_id": os.environ.get("GITHUB_ACTOR_ID"),
            "runner_os": os.environ["RUNNER_OS"],
            "runner_arch": os.environ["RUNNER_ARCH"],
        },
        "oidc_claims": oidc_claims,
        "tailscale": tailscale,
        "stages": stages,
        "integrity": {
            "generated_at": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "collector_version": "0.2.0",
            "policy_version": "wif-basic-deployment-1",
        },
    }
    output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()

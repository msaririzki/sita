#!/usr/bin/env bash

set -euo pipefail

stage_name="${1:?stage name is required}"
stage_status="${2:?stage status is required}"
reason_code="${3:-}"
message="${4:-}"

: "${AUTH_OBSERVATORY_URL:?AUTH_OBSERVATORY_URL is required}"
: "${INPUT_EXPERIMENT_ID:?INPUT_EXPERIMENT_ID is required}"
: "${INPUT_TRIAL_ID:?INPUT_TRIAL_ID is required}"
: "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?ACTIONS_ID_TOKEN_REQUEST_TOKEN is required}"
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?ACTIONS_ID_TOKEN_REQUEST_URL is required}"

audience="${AUTH_OBSERVATORY_URL%/}/api/v1/progress"
encoded_audience="$(AUDIENCE="${audience}" python3 -c 'import os, urllib.parse; print(urllib.parse.quote(os.environ["AUDIENCE"], safe=""))')"
response="$(curl --fail --silent --show-error --max-time 15 \
    -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${encoded_audience}")"
progress_token="$(RESPONSE="${response}" python3 -c 'import json, os; print(json.loads(os.environ["RESPONSE"])["value"])')"
echo "::add-mask::${progress_token}"

STAGE_NAME="${stage_name}" \
STAGE_STATUS="${stage_status}" \
REASON_CODE="${reason_code}" \
MESSAGE="${message}" \
python3 - <<'PY' | curl --fail --silent --show-error --max-time 15 \
    -H "Authorization: Bearer ${progress_token}" \
    -H 'Content-Type: application/json' \
    --data-binary @- \
    "${audience}" >/dev/null
import json
import os

stage = {
    "name": os.environ["STAGE_NAME"],
    "status": os.environ["STAGE_STATUS"],
}
if os.environ["REASON_CODE"]:
    stage["reason_code"] = os.environ["REASON_CODE"]
if os.environ["MESSAGE"]:
    stage["message"] = os.environ["MESSAGE"]

print(json.dumps({
    "experiment_id": os.environ["INPUT_EXPERIMENT_ID"],
    "trial_id": os.environ["INPUT_TRIAL_ID"],
    "stage": stage,
}))
PY

unset response progress_token

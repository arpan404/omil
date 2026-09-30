#!/bin/bash
# Submit a distribution artifact and retain Apple's result and diagnostic log.
set +x
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
[[ $# -eq 2 ]] || { echo 'Usage: notarize-file.sh <artifact> <log-prefix>' >&2; exit 1; }
artifact=$1
prefix=$2
# shellcheck source=scripts/release-env.sh
source scripts/release-env.sh
configure_apple_api_auth
result_json="${prefix}-result.json"
submit_exit=0
xcrun notarytool submit "$artifact" "${notary_auth[@]}" \
  --wait --output-format json > "$result_json" || submit_exit=$?
json_field() {
  /usr/bin/python3 - "$result_json" "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get(sys.argv[2], ''))
except (ValueError, OSError):
    pass
PY
}
submission_id=$(json_field id)
status=$(json_field status)
if [[ -n $submission_id ]]; then
  echo "Notarization submission: $submission_id ($status)"
  xcrun notarytool log "$submission_id" "${notary_auth[@]}" "${prefix}-log.json" \
    || echo "Could not retrieve Apple's diagnostic log." >&2
fi
[[ $submit_exit -eq 0 && $status == Accepted ]] || {
  echo "error: notarization was not accepted; inspect $result_json and ${prefix}-log.json" >&2
  exit 1
}

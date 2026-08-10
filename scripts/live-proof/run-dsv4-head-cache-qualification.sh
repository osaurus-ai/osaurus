#!/usr/bin/env bash
set -euo pipefail

# This launcher is the only entry point that may create the campaign rails or
# start an app process.  The verifier's pre_campaign phase runs first and
# hashes every model inventory entry once.  The later matrix positions use its
# process phase, which checks identity and size but deliberately does not
# rehash the model shards.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/../.." && pwd -P)"
manifest_path="${OSAURUS_DSV4_QUALIFICATION_MANIFEST:-/Users/mmeding/Developer/Models-0731-Osaurus/07-validation/head-cache-campaign/qualification-manifest-v1.json}"
manifest_sha256="${OSAURUS_DSV4_QUALIFICATION_MANIFEST_SHA256:-}"
dry_run="${OSAURUS_DSV4_QUALIFICATION_DRY_RUN:-0}"
run_live="${OSAURUS_DSV4_RUN_LIVE:-0}"

if [[ -z "$manifest_sha256" ]]; then
    echo "FAIL OSAURUS_DSV4_QUALIFICATION_MANIFEST_SHA256 is required" >&2
    exit 2
fi

case "$manifest_path" in
    "$repo_root"|"$repo_root"/*)
        echo "FAIL the generated manifest must remain outside the Git worktree: $manifest_path" >&2
        exit 2
        ;;
esac

if [[ "$dry_run" == "1" ]]; then
    python3 "$script_dir/verify-dsv4-head-cache-qualification.py" \
        "$manifest_path" \
        --expected-sha256 "$manifest_sha256" \
        --phase pre_campaign \
        --json
    echo "DRY-RUN no campaign root was created and no Osaurus process was started" >&2
    exit 0
fi

if [[ "$run_live" == "1" ]]; then
    echo "FAIL live Gate 4/5 execution is not implemented; this launcher is schema/plan-only" >&2
    exit 2
fi

# This command verifies the complete manifest, then reserves output rails. No
# output directory, ledger, process, or arm exists before the verification
# branch in reserve_output returns.
reservation_json="$(python3 "$script_dir/verify-dsv4-head-cache-qualification.py" \
    "$manifest_path" \
    --expected-sha256 "$manifest_sha256" \
    --phase pre_campaign \
    --reserve-output \
    --json)"
printf '%s\n' "$reservation_json"

campaign_root="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["campaign_root"])' <<<"$reservation_json")"
state_dir="$campaign_root/state"

python3 "$script_dir/dsv4-head-cache-gate-matrix.py" \
    "$manifest_path" \
    --expected-sha256 "$manifest_sha256" \
    --out "$state_dir/gate-matrix-plan.json"
echo "PLAN-ONLY no Osaurus process was started and no live gate was claimed" >&2
exit 0

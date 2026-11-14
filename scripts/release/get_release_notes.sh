#!/usr/bin/env bash
set -euo pipefail

# Keep target release notes isolated. Selection is read-only: unrelated drafts
# remain available, including the rolling Next Release draft.
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec python3 "$script_dir/release_notes.py"

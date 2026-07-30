#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$ROOT_DIR/docs/private-chat-harness.md"

python3 - "$DOC" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
if re.search(r"<[^>]+>", text):
    raise SystemExit("documentation contains an executable angle-bracket placeholder")

blocks = re.findall(r"```bash\n(.*?)```", text, re.S)
harness_blocks = [block for block in blocks if "utils/private-chat-harness.sh" in block]
if len(harness_blocks) != 3:
    raise SystemExit("expected exactly preflight, activate, and cleanup harness commands")

required = (
    "ALLOW_LOCAL_FEATURE_REFS=1",
    "DAIANA_HARNESS_MODE=local-candidate",
    "DAIANA_HARNESS_OPERATION=candidate",
    "DAIANA_DEPLOYMENT_MODE=local-candidate",
    "DAIANA_HARNESS_NO_PUSH=1",
    "DAIANA_HARNESS_NO_PUBLICATION=1",
    "DAIANA_HARNESS_NO_REGISTRY_PUBLISH=1",
)
for index, block in enumerate(harness_blocks, 1):
    command = block.replace("\\\n", " ")
    subprocess.run(["bash", "-n"], input=command, text=True, check=True)
    missing = [flag for flag in required if flag not in block]
    if missing:
        raise SystemExit("harness command %d is missing: %s" % (index, ", ".join(missing)))

if 'POSTGRES_PASSWORD="$POSTGRES_PASSWORD"' not in harness_blocks[0] or 'POSTGRES_DB="$POSTGRES_DB"' not in harness_blocks[0]:
    raise SystemExit("preflight must document both required PostgreSQL variable names")
if 'POSTGRES_PASSWORD="$POSTGRES_PASSWORD"' not in harness_blocks[1] or 'POSTGRES_DB="$POSTGRES_DB"' not in harness_blocks[1]:
    raise SystemExit("activation must document both required PostgreSQL variable names")
if "fsynced" not in text or "retry blocked" not in text:
    raise SystemExit("documentation does not describe durable retained state")

if "DAIANA_CANDIDATE_NEXT_IMAGE=cloudseidoranalytics/daiana:sha-90bd701c3eec30f7d3b56fb230050f7e46fd98bf" not in harness_blocks[0]:
    raise SystemExit("preflight does not document the exact approved Front image ref")
if "DAIANA_CANDIDATE_PYTHON_IMAGE=cloudseidoranalytics/daianapython:sha-16e161f468f1976d15ba40b1312dc5f247d64dab" not in harness_blocks[0]:
    raise SystemExit("preflight does not document the exact approved Python image ref")
print("PASS: documented harness commands parse and carry every mandatory local guard")
PY

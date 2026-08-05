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
normalized_text = " ".join(text.split())
if "PRIVATE_CHAT_PYTHON_ORIGIN=\"$PRIVATE_CHAT_PYTHON_ORIGIN\"" not in harness_blocks[0] or "PRIVATE_CHAT_PYTHON_ORIGIN" not in normalized_text:
    raise SystemExit("documentation does not describe the required candidate Python origin")
if "origin-only HTTP/HTTPS URL" not in normalized_text or "private/loopback `nip.io` hosts" not in normalized_text:
    raise SystemExit("documentation does not describe the local origin policy")

if "DAIANA_CANDIDATE_NEXT_IMAGE=cloudseidoranalytics/daiana:sha-503d3c65bce2d9ec68d714010f680f702052c3dc" not in harness_blocks[0]:
    raise SystemExit("preflight does not document the exact approved Front image ref")
if "Python and Teams use their local `develop` refs, while Studio uses its fixed local `feat/daiana-313` ref" not in normalized_text:
    raise SystemExit("documentation does not record the fixed per-repository source baselines")
if "Daiana quota changes" not in text:
    raise SystemExit("documentation does not explain the Studio baseline rationale")
expected_refs = (
    "DAIANA_CANDIDATE_PYTHON_IMAGE=cloudseidoranalytics/daianapython:sha-c2694d4a7ac766da8c730a7e4cb6b82759a9332a",
    "DAIANA_CANDIDATE_MSTEAMS_IMAGE=cloudseidoranalytics/daianamsteams:sha-f546bb0ff6272f11a892f5107ef0b1c4462f5b89",
    "DAIANA_CANDIDATE_STUDIO_IMAGE=cloudseidoranalytics/daianastudio:sha-ed872073e7f359e7b8c88c6c2a26f55c46582c69",
    "DAIANA_APPROVED_NEXT_SOURCE_SHA=503d3c65bce2d9ec68d714010f680f702052c3dc",
    "DAIANA_APPROVED_PYTHON_SOURCE_SHA=c2694d4a7ac766da8c730a7e4cb6b82759a9332a",
    "DAIANA_APPROVED_MSTEAMS_SOURCE_SHA=f546bb0ff6272f11a892f5107ef0b1c4462f5b89",
    "DAIANA_APPROVED_STUDIO_SOURCE_SHA=ed872073e7f359e7b8c88c6c2a26f55c46582c69",
)
missing_refs = [ref for ref in expected_refs if ref not in harness_blocks[0]]
if missing_refs:
    raise SystemExit("preflight does not document exact four-service source refs: %s" % ", ".join(missing_refs))
if "1571fc1e7e7f11038168dd1a6673cdd50777efa1" not in text:
    raise SystemExit("documentation does not preserve the previously approved Teams tuple")
if "28174f50391b6fa83d7cf97382a756f5d2f5fcb1" not in text or "older approved" not in normalized_text:
    raise SystemExit("documentation does not preserve all older approved Teams tuples")
print("PASS: documented harness commands parse and carry every mandatory local guard")
PY

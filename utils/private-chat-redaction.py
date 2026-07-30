#!/usr/bin/env python3
"""Redact untrusted diagnostic text and fail closed on unsafe artifacts."""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path


SENSITIVE_KEY = re.compile(
    r"(?i)^(?:password|passwd|token|secret|api[_-]?key|access[_-]?token|"
    r"refresh[_-]?token|cookie|authorization|database[_-]?url|private[_-]?key|"
    r"client[_-]?secret|passphrase|credential|credentials|[a-z][a-z0-9_.-]*"
    r"(?:pass(?:word)?|token|secret|api[_-]?key|private[_-]?key))$"
)
ASSIGNMENT = re.compile(
    r'''(?ix)(?P<key>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[A-Za-z_][A-Za-z0-9_.-]*)'''
    r'''\s*(?::|=)\s*(?P<value>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|(?![\{\[])[^\s,;}\]=]+)(?!\s*=)'''
)
SENSITIVE_KEY_PATTERN = (
    r"(?:password|passwd|token|secret|api[_-]?key|access[_-]?token|"
    r"refresh[_-]?token|cookie|authorization|database[_-]?url|private[_-]?key|"
    r"client[_-]?secret|passphrase|credential|credentials|[a-z][a-z0-9_.-]*"
    r"(?:pass(?:word)?|token|secret|api[_-]?key|private[_-]?key))"
)
SENSITIVE_ASSIGNMENT = re.compile(
    rf'''(?ix)(?<![A-Za-z0-9_.-])(?P<key>"{SENSITIVE_KEY_PATTERN}"|'{SENSITIVE_KEY_PATTERN}'|{SENSITIVE_KEY_PATTERN})'''
    rf'''\s*(?::|=)\s*(?P<value>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|(?![\{{\[])[^\s,;}}\]=]+)(?!\s*=)'''
)
URL = re.compile(r"(?i)\b(?:https?|wss?|ws|ftp|postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|redis|rediss)://[^\s'\"<>]+")
BEARER = re.compile(r"(?i)\bbearer\s+[^\s'\"<>]+")
HEADER = re.compile(r"(?im)\b(?:authorization|proxy-authorization|x-api-key)\s*:\s*[^\r\n,]+")
PRIVATE_KEY = re.compile(r"(?is)-----BEGIN [^-\r\n]*PRIVATE KEY-----.*?-----END [^-\r\n]*PRIVATE KEY-----")
PRIVATE_KEY_MARKER = re.compile(r"(?i)-----\s*(?:BEGIN|END)\s+[^\r\n-]*PRIVATE KEY\s*-----")
SSH_KEY = re.compile(r"(?m)\bssh-(?:rsa|ed25519|ecdsa)\s+[A-Za-z0-9+/=]+(?:\s+[^\s]+)?")
PATH = re.compile(r"(?<![A-Za-z0-9_.-])(?:~|/|\.\.?/|\$HOME(?:/|$)|\$\{HOME\}(?:/|$))[^\s'\"<>;,)]*")
SHELL_SECRET_OPTION = re.compile(
    r'''(?ix)(?<![A-Za-z0-9_-])(?P<option>--(?:[a-z0-9]+[-_])*?(?:password|passwd|pass|token|api-key|secret)(?:[-_][a-z0-9]+)*(?:=|\s+)|-p(?:\s+|(?=[^\s;&|<>])))'''
    r'''(?P<value>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|(?:\\.|[^\s;&|<>])+)'''
)
SAFE_VALUES = {"", "[redacted]", "redacted", "unknown", "none", "null"}


def normalize(text: str) -> str:
    """Expose escaped JSON/YAML/shell syntax to the same policy scanner."""
    for _ in range(3):
        text = text.replace(r"\/", "/").replace(r"\\", "\\")
        text = text.replace(r'\"', '"').replace(r"\'", "'")
        text = re.sub(r"\\u([0-9a-f]{4})", lambda m: chr(int(m.group(1), 16)), text, flags=re.I)
    return text


def _key(match: re.Match[str]) -> str:
    return match.group("key").strip("\"'")


def _redacted_value(value: str) -> str:
    if value[:1] in {"'", '"'} and value[-1:] == value[:1]:
        return value[:1] + "[REDACTED]" + value[-1:]
    return "[REDACTED]"


def _option_value_is_safe(match: re.Match[str]) -> bool:
    value = match.group("value").strip("\"'").strip().lower()
    # -p is a password for some clients but a numeric port for others.
    option = match.group("option").strip()
    return value in SAFE_VALUES or (option == "-p" and value.isdigit())


def _sensitive_path(value: str) -> bool:
    """Redact paths that can disclose credentials or private material."""
    path = value.rstrip("/.").lower()
    components = set(re.split(r"[/\\]+", path))
    sensitive = {
        ".ssh", ".config", ".aws", ".gnupg", "keychain", "credentials",
        "credential", "secrets", "secret", "private", "id_rsa", "id_ed25519",
        "id_ecdsa", "known_hosts",
    }
    return bool(components & sensitive) or path.endswith((".pem", ".key", ".p12", ".pfx", ".kdbx"))


def redact(text: str) -> str:
    text = normalize(text)

    def replace_assignment(match: re.Match[str]) -> str:
        if not SENSITIVE_KEY.match(_key(match)):
            return match.group(0)
        start = match.start("value") - match.start()
        return match.group(0)[:start] + _redacted_value(match.group("value"))

    text = URL.sub("[REDACTED_URL]", text)
    text = HEADER.sub("[REDACTED_HEADER]", text)
    text = BEARER.sub("Bearer [REDACTED]", text)
    text = PRIVATE_KEY.sub("[REDACTED_PRIVATE_KEY]", text)
    text = PRIVATE_KEY_MARKER.sub("[REDACTED_PRIVATE_KEY]", text)
    text = SSH_KEY.sub("[REDACTED_SSH_KEY]", text)
    text = SHELL_SECRET_OPTION.sub(
        lambda m: m.group(0) if _option_value_is_safe(m) else m.group("option") + _redacted_value(m.group("value")),
        text,
    )
    for _ in range(3):
        text = SENSITIVE_ASSIGNMENT.sub(replace_assignment, text)
    text = ASSIGNMENT.sub(replace_assignment, text)
    text = PATH.sub(lambda m: "[REDACTED_PATH]" if _sensitive_path(m.group(0)) else m.group(0), text)
    return text


def unsafe(text: str) -> bool:
    normalized = normalize(text)
    if any(pattern.search(normalized) for pattern in (URL, HEADER, BEARER, PRIVATE_KEY, PRIVATE_KEY_MARKER, SSH_KEY)):
        return True
    if any(_sensitive_path(match.group(0)) for match in PATH.finditer(normalized)):
        return True
    for match in SHELL_SECRET_OPTION.finditer(normalized):
        if not _option_value_is_safe(match):
            return True
    for matcher in (SENSITIVE_ASSIGNMENT, ASSIGNMENT):
        for match in matcher.finditer(normalized):
            if SENSITIVE_KEY.match(_key(match)) and match.group("value").strip("\"'").strip().lower() not in SAFE_VALUES:
                return True
    postgres_password = os.environ.get("POSTGRES_PASSWORD")
    return bool(postgres_password and postgres_password in normalized)


def verify_directory(directory: str) -> int:
    root = Path(directory)
    terminal_names = {"failure-diagnostics.txt", "manual-cleanup-required", "migrations-committed.receipt", "migrations-applied.receipt", "active"}
    for path in root.rglob("*") if root.exists() else ():
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        if path.name in terminal_names:
            states = [line.split("=", 1)[1].strip() for line in text.splitlines() if line.startswith("state=") and "=" in line]
            if len(states) != 1 or not states[0]:
                print(f"ERROR: retained terminal artifact has an empty or missing state: {path}", file=sys.stderr)
                return 1
        if unsafe(text):
            print(f"ERROR: retained artifact contains a forbidden secret-like value: {path}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--verify-dir":
        raise SystemExit(verify_directory(sys.argv[2]))
    sys.stdout.write(redact(sys.stdin.read()))

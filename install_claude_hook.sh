#!/usr/bin/env sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE_SCRIPT="$SCRIPT_DIR/terminal_pin_notice.py"
SOURCE_HOOK="$SCRIPT_DIR/remind_me.ps1"
REQUIREMENTS_FILE="$SCRIPT_DIR/requirements.txt"
PIN_SECONDS=${PIN_SECONDS:-1}

if [ ! -f "$SOURCE_SCRIPT" ]; then
    printf '%s\n' "Error: terminal_pin_notice.py was not found beside this installer." >&2
    exit 1
fi

if [ ! -f "$SOURCE_HOOK" ]; then
    printf '%s\n' "Error: remind_me.ps1 was not found beside this installer." >&2
    exit 1
fi

case "$PIN_SECONDS" in
    ''|*[!0-9]*)
        printf '%s\n' "Error: PIN_SECONDS must be a positive integer." >&2
        exit 1
        ;;
esac

if [ "$PIN_SECONDS" -le 0 ]; then
    printf '%s\n' "Error: PIN_SECONDS must be greater than 0." >&2
    exit 1
fi

if [ -n "${PYTHON:-}" ]; then
    PYTHON_COMMAND=$PYTHON
elif command -v python >/dev/null 2>&1; then
    PYTHON_COMMAND=python
elif command -v python3 >/dev/null 2>&1; then
    PYTHON_COMMAND=python3
else
    printf '%s\n' "Error: Python was not found in PATH." >&2
    exit 1
fi

if ! "$PYTHON_COMMAND" -c 'import tkinter' >/dev/null 2>&1; then
    printf '%s\n' "Error: Python Tkinter is unavailable. Reinstall Python with Tcl/Tk enabled." >&2
    exit 1
fi

if ! "$PYTHON_COMMAND" -m pip --version >/dev/null 2>&1; then
    printf '%s\n' "pip was not found. Bootstrapping pip with ensurepip..."
    "$PYTHON_COMMAND" -m ensurepip --upgrade
fi

if [ -f "$REQUIREMENTS_FILE" ]; then
    printf '%s\n' "Installing packages from requirements.txt..."
    "$PYTHON_COMMAND" -m pip install -r "$REQUIREMENTS_FILE"
else
    printf '%s\n' "No requirements.txt found; skipping pip package installation."
fi

if [ -n "${PIP_PACKAGES:-}" ]; then
    printf '%s\n' "Installing packages from PIP_PACKAGES..."
    # Space-separated package specifications, for example: requests rich==13.9.4
    # shellcheck disable=SC2086
    "$PYTHON_COMMAND" -m pip install $PIP_PACKAGES
fi

SOURCE_SCRIPT="$SOURCE_SCRIPT" SOURCE_HOOK="$SOURCE_HOOK" PIN_SECONDS="$PIN_SECONDS" "$PYTHON_COMMAND" - <<'PY'
import json
import os
import shutil
from datetime import datetime
from pathlib import Path


source = Path(os.environ["SOURCE_SCRIPT"]).resolve()
source_hook = Path(os.environ["SOURCE_HOOK"]).resolve()
seconds = int(os.environ["PIN_SECONDS"])
claude_dir = Path.home() / ".claude"
target = claude_dir / source.name
target_hook = claude_dir / source_hook.name
settings_path = claude_dir / "settings.json"

claude_dir.mkdir(parents=True, exist_ok=True)
shutil.copy2(source, target)
shutil.copy2(source_hook, target_hook)

if settings_path.exists():
    original_text = settings_path.read_text(encoding="utf-8")
    backup_path = settings_path.with_name(
        f"settings.json.backup-{datetime.now():%Y%m%d-%H%M%S}"
    )
else:
    original_text = "{}\n"
    backup_path = None

try:
    settings = json.loads(original_text)
except json.JSONDecodeError as error:
    raise SystemExit(f"Error: invalid Claude settings.json: {error}")

if not isinstance(settings, dict):
    raise SystemExit("Error: Claude settings.json must contain a JSON object.")

hooks = settings.get("hooks", {})
if not isinstance(hooks, dict):
    raise SystemExit("Error: Claude settings.json has an invalid 'hooks' value.")

stop_hooks = hooks.get("Stop", [])
if not isinstance(stop_hooks, list):
    raise SystemExit("Error: Claude settings.json has an invalid 'hooks.Stop' value.")

target_hook_text = target_hook.as_posix()
command = (
    f'powershell.exe -NoProfile -ExecutionPolicy Bypass -File '
    f'"{target_hook_text}" -PinSeconds {seconds}'
)
command_hook = {"type": "command", "command": command}
stop_entry = {"hooks": [command_hook]}

already_configured = any(
    isinstance(entry, dict)
    and any(
        isinstance(item, dict) and item.get("command") == command
        for item in entry.get("hooks", [])
    )
    for entry in stop_hooks
)

if not already_configured:
    stop_hooks.append(stop_entry)

def skip_string(text, index):
    index += 1
    while index < len(text):
        if text[index] == "\\":
            index += 2
        elif text[index] == '"':
            return index + 1
        else:
            index += 1
    raise ValueError("unterminated JSON string")


def skip_value(text, index):
    while index < len(text) and text[index].isspace():
        index += 1
    if text[index] == '"':
        return skip_string(text, index)
    if text[index] in "[{":
        opening = text[index]
        closing = "]" if opening == "[" else "}"
        depth = 0
        while index < len(text):
            if text[index] == '"':
                index = skip_string(text, index)
                continue
            if text[index] == opening:
                depth += 1
            elif text[index] == closing:
                depth -= 1
                if depth == 0:
                    return index + 1
            index += 1
        raise ValueError("unterminated JSON value")
    while index < len(text) and text[index] not in ",]}\n\r":
        index += 1
    return index


def object_property(text, object_start, name):
    index = object_start + 1
    while index < len(text):
        while index < len(text) and text[index].isspace():
            index += 1
        if text[index] == "}":
            return None
        key_start = index
        index = skip_string(text, index)
        key = json.loads(text[key_start:index])
        while text[index].isspace():
            index += 1
        if text[index] != ":":
            raise ValueError("invalid JSON object")
        value_start = index + 1
        value_end = skip_value(text, value_start)
        if key == name:
            return value_start, value_end
        index = value_end
        while index < len(text) and text[index].isspace():
            index += 1
        if index < len(text) and text[index] == ",":
            index += 1
    return None


def replace_stop_value(text, serialized_stop):
    hooks_property = object_property(text, 0, "hooks")
    if hooks_property is None:
        body = text.rstrip()
        closing = body.rfind("}")
        prefix = "," if body[:closing].strip() != "{" else ""
        addition = f'{prefix}\n  "hooks": {{\n    "Stop": {serialized_stop}\n  }}\n'
        return body[:closing] + addition + body[closing:] + "\n"

    hooks_start, hooks_end = hooks_property
    stop_property = object_property(text, hooks_start, "Stop")
    if stop_property is not None:
        start, end = stop_property
        return text[:start] + serialized_stop + text[end:]

    closing = hooks_end - 1
    body = text[:closing].rstrip()
    prefix = "," if body[-1] != "{" else ""
    addition = f'{prefix}\n    "Stop": {serialized_stop}\n'
    return body + addition + text[closing:]


serialized_stop = json.dumps(stop_hooks, ensure_ascii=False, indent=2)
updated_text = replace_stop_value(original_text, serialized_stop)
if updated_text != original_text:
    if backup_path:
        shutil.copy2(settings_path, backup_path)
    temporary_path = settings_path.with_suffix(".json.tmp")
    temporary_path.write_text(updated_text, encoding="utf-8", newline="\n")
    temporary_path.replace(settings_path)

print(f"Installed helper: {target}")
print(f"Installed Stop hook script: {target_hook}")
print(f"Updated Claude settings: {settings_path}")
if backup_path and updated_text != original_text:
    print(f"Backup created: {backup_path}")
if already_configured:
    print("Stop hook was already configured; no duplicate was added.")
else:
    print(f"Stop hook added with a {seconds}-second pin duration.")
PY

printf '%s\n' "Done. Restart Claude Code if it was already running."
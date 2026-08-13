#!/usr/bin/env bash

set -euo pipefail

INPUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/settings"
OUTPUT="$HOME/.config/Code/User"

# Keys in settings.json whose value belongs to this machine rather than to the
# repo. The repo still declares them, but the machine's current value is carried
# over so that state accumulated locally is not thrown away. Every other key
# comes from the repo. cSpell.userWords is the spell-check dictionary, which is
# built up word by word while editing and exists nowhere else.
PRESERVE=("cSpell.userWords")

# Scratch space for the rendered settings.json, computed during the preview and
# reused by the write phase so the two can never drift. The current/ and new/
# split is what the diff header shows, so it names the two sides. Cleaned up on
# exit.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/current" "$WORK/new"

# render <base> [<preserve-source> <key>...]
# Print <base> as canonical JSON (sorted keys, two-space indent). VS Code writes
# JSONC — comments and trailing commas — which a strict JSON parser rejects, so
# the input is scanned and stripped first. The scan copies string literals
# verbatim, otherwise a "//" inside a value such as a URL would be mistaken for
# the start of a comment. When a preserve-source is given, the listed keys are
# taken from it instead of from <base>; keys it does not have are left alone.
render() {
    python3 - "$@" <<'PY'
import json
import sys


def read_jsonc(path):
    src = open(path, encoding='utf-8').read()
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == '\\' else 1
            out.append(src[i:j + 1])
            i = j + 1
        elif src.startswith('//', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
        elif src.startswith('/*', i):
            j = src.find('*/', i + 2)
            i = n if j < 0 else j + 2
        else:
            # A closing bracket preceded by nothing but a comma and whitespace
            # means that comma was a trailing one, so drop it.
            if c in '}]':
                k = len(out) - 1
                while k >= 0 and out[k].strip() == '':
                    k -= 1
                if k >= 0 and out[k] == ',':
                    out.pop(k)
            out.append(c)
            i += 1
    return json.loads(''.join(out))


def load(path):
    try:
        return read_jsonc(path)
    except (OSError, ValueError) as error:
        sys.exit('Error: cannot read %s: %s' % (path, error))


data = load(sys.argv[1])

if len(sys.argv) > 2:
    machine = load(sys.argv[2])
    for key in sys.argv[3:]:
        if key in machine:
            data[key] = machine[key]

sys.stdout.write(json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + '\n')
PY
}

# preview_file <src> <tgt> <label> [<tgt_view>]
# Print a one-line status for the file and, when it changed, a colored diff of
# the current target against the incoming content. <tgt_view> is the rendering
# of <tgt> the diff is shown against, so that a file which is rewritten in a
# different layout is compared by meaning rather than byte for byte; it defaults
# to <tgt>. Never writes anything. Returns 0 when the target is already what it
# should be, 1 when it needs to be written.
preview_file() {
    local src="$1" tgt="$2" label="$3" tgt_view="${4:-$2}"

    if [ ! -e "$tgt" ]; then
        echo "NEW:       $label (target does not exist, will be created)"
        return 1
    fi

    if cmp -s "$src" "$tgt"; then
        echo "unchanged: $label"
        return 0
    fi

    if cmp -s "$src" "$tgt_view"; then
        echo "reformat:  $label (formatting only, no value changes)"
        return 1
    fi

    echo "changed:   $label"
    git diff --no-index --color=auto -- "$tgt_view" "$src" || true
    return 1
}

# --- Preview (read-only) ----------------------------------------------------

# A missing target directory means VS Code is not installed or has never been
# launched. Creating it would leave a config directory that nothing ever reads,
# so stop instead.
if [ ! -d "$OUTPUT" ]; then
    echo "Error: $OUTPUT does not exist." >&2
    echo "Install VS Code and launch it once, then run this again." >&2
    exit 1
fi

echo "Previewing changes against $OUTPUT"
echo

# settings.json: the repo wins for every key except the preserved ones. The
# machine file is rendered the same way as the result before being diffed, so
# the preview shows the settings that actually change rather than the whole file
# reordered.
settings_changed=0
if [ -f "$OUTPUT/settings.json" ]; then
    render "$INPUT/settings.json" "$OUTPUT/settings.json" "${PRESERVE[@]}" > "$WORK/new/settings.json"
    render "$OUTPUT/settings.json" > "$WORK/current/settings.json"
    preview_file "$WORK/new/settings.json" "$OUTPUT/settings.json" "settings.json" \
        "$WORK/current/settings.json" || settings_changed=1
else
    render "$INPUT/settings.json" > "$WORK/new/settings.json"
    preview_file "$WORK/new/settings.json" "$OUTPUT/settings.json" "settings.json" || settings_changed=1
fi

# keybindings.json is an array of bindings with no keys to preserve, so it is
# copied byte for byte and diffed as it is.
keybindings_changed=0
preview_file "$INPUT/keybindings.json" "$OUTPUT/keybindings.json" "keybindings.json" \
    || keybindings_changed=1

if [ "$settings_changed" -eq 0 ] && [ "$keybindings_changed" -eq 0 ]; then
    echo
    echo "Already up to date. Nothing to do."
    exit 0
fi

# --- Confirm ----------------------------------------------------------------

echo
printf 'Proceed with deploy? [y/n] '
read -r reply || reply=""
case "$reply" in
    [yY] | [yY][eE][sS]) ;;
    *)
        echo "Aborted. Nothing was written."
        exit 0
        ;;
esac

# --- Write ------------------------------------------------------------------

if [ "$settings_changed" -eq 1 ]; then
    cp "$WORK/new/settings.json" "$OUTPUT/settings.json"
fi

if [ "$keybindings_changed" -eq 1 ]; then
    cp "$INPUT/keybindings.json" "$OUTPUT/keybindings.json"
fi

echo "Deployed VS Code settings to $OUTPUT"

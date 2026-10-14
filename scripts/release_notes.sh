#!/usr/bin/env bash
# Prints the body of one CHANGELOG.md section: ./scripts/release_notes.sh 1.2.0 (or Unreleased).
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
    echo "usage: $0 <version|Unreleased>" >&2
    exit 2
fi
SECTION="$1"
CHANGELOG="${CHANGELOG:-$(cd "$(dirname "$0")/.." && pwd)/CHANGELOG.md}"
[[ -f "$CHANGELOG" ]] || { echo "error: $CHANGELOG not found" >&2; exit 1; }

# Section runs from "## [<name>]" to the next "## " heading or the link footer.
# Leading and trailing blank lines are dropped.
BODY="$(awk -v want="$SECTION" '
    /^## / {
        if (found) exit
        name = $0
        sub(/^## \[/, "", name)
        sub(/\].*$/, "", name)
        if (tolower(name) == tolower(want)) found = 1
        next
    }
    found && /^\[[^]]+\]: / { exit }
    found {
        if ($0 ~ /^[[:space:]]*$/) { blank++; next }
        if (printed) for (i = 0; i < blank; i++) print ""
        blank = 0
        printed = 1
        print
    }
    END { if (!found) exit 3 }
' "$CHANGELOG")" || {
    status=$?
    if [[ $status -eq 3 ]]; then
        echo "error: no \"## [$SECTION]\" section in $CHANGELOG" >&2
    fi
    exit 1
}

if [[ -z "$BODY" ]]; then
    echo "error: the \"$SECTION\" section in $CHANGELOG is empty" >&2
    exit 1
fi
printf '%s\n' "$BODY"

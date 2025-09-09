#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")"/.. && pwd)"

failed=0

for script in $(find "$DIR/linux" -name '*.sh'); do
    echo "Checking $script"
    if ! bash -n "$script"; then
        echo "Shell syntax error in $script"
        failed=1
    fi
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck "$script" || failed=1
    fi
done

if command -v pwsh >/dev/null 2>&1; then
    for ps_script in $(find "$DIR/windows" -name '*.ps1'); do
        echo "Checking $ps_script"
        if ! pwsh -NoProfile -Command "[System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw '$ps_script'), [ref]0) > \$null"; then
            echo "PowerShell syntax error in $ps_script"
            failed=1
        fi
    done
else
    echo "pwsh not available; skipping PowerShell checks"
fi

if [[ $failed -eq 0 ]]; then
    echo "All tests passed."
else
    echo "Some tests failed." >&2
fi
exit $failed

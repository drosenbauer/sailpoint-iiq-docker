#!/bin/bash
# Opens a shell in a running container: WHICH=ldap bin/enter-shell.sh (default: iiq)

cd "$(dirname "$0")/.." || exit 1
source bin/include/utils.sh

# Git Bash: don't rewrite /bin/bash into a Windows path, and run through winpty
# under mintty, where docker otherwise says "the input device is not a TTY"
export MSYS_NO_PATHCONV=1
WINPTY=()
if is_windows && [[ "${TERM_PROGRAM}" == "mintty" ]] && command -v winpty > /dev/null 2>&1; then
	WINPTY=(winpty)
fi

"${WINPTY[@]}" docker compose exec "${WHICH:-iiq}" /bin/bash

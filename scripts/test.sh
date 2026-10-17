#!/usr/bin/env bash
# Run the busted suite, then luacheck. Run from anywhere:
#   MSYS_NO_PATHCONV=1 wsl.exe -e bash scripts/test.sh [spec files]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# busted and luacheck live in the user's luarocks tree (not on the default PATH).
eval "$(luarocks --lua-version=5.1 path --bin)"

busted "$@"
luacheck --quiet --no-color Taxi tests

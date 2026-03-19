#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[[ $EUID -ne 0 ]] && { echo "Must run as root"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_NAME="$(basename "$(cd "${SCRIPT_DIR}/.." && pwd)")"
MODULE_NAME="$(basename "${SCRIPT_DIR}")"
DEST="/etc/${REPO_NAME}/${MODULE_NAME}"

mkdir -p "$DEST"

for script in setup.sh remove.sh enforce-all.sh; do
    src="$SCRIPT_DIR/$script"
    dst="$DEST/$script"

    if [[ ! -f "$src" ]]; then
        error "$src not found"
        exit 1
    fi

    if [[ -f "$dst" ]]; then
        warn "$dst already exists — overwriting."
    fi

    cp "$src" "$dst"
    chmod 700 "$dst"
    info "Installed $dst"
done

echo ""
info "Run the following to configure AppArmor:"
echo "  sudo $DEST/setup.sh"
echo ""
echo "Options:"
echo "  --complain    Stage profiles in complain mode (logs only); enforce later with:"
echo "                sudo $DEST/enforce-all.sh"

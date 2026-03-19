#!/usr/bin/env bash
# install.sh — Discover all modules and run their install.sh if present
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[arch-scripts]${NC} $*"; }
warn()  { echo -e "${YELLOW}[arch-scripts]${NC} $*"; }
error() { echo -e "${RED}[arch-scripts]${NC} $*" >&2; }

[[ $EUID -eq 0 ]] || { error "Must run as root: sudo $0"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=()

for module_dir in "$SCRIPT_DIR"/*/; do
    module="$(basename "$module_dir")"
    [[ "$module" != .* ]] || continue
    script="$module_dir/install.sh"
    [[ -f "$script" ]] || continue

    info "Installing module: $module"
    if bash "$script"; then
        info "$module — done"
    else
        error "$module — failed (exit $?)"
        failed+=("$module")
    fi
    echo ""
done

if (( ${#failed[@]} )); then
    error "Failed modules: ${failed[*]}"
    exit 1
else
    info "All modules installed successfully."
fi

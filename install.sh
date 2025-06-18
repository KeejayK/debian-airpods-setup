#!/usr/bin/env bash

# installer for setup-airpods.sh
set -euo pipefail

TARGET_DIR="$HOME/bin"
SCRIPT_SRC="connect-airpods.sh"

# create target
mkdir -p "$TARGET_DIR"

# copy
cp "$SCRIPT_SRC" "$TARGET_DIR/"
chmod +x "$TARGET_DIR/$(basename "$SCRIPT_SRC")"

echo "Installed '$(basename "$SCRIPT_SRC")' to $TARGET_DIR"
echo "Make sure '$TARGET_DIR' is in your PATH."
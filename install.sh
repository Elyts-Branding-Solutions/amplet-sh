#!/bin/sh
# Install amplet from GitHub Releases.
# Usage (no token): curl -fsSL https://raw.githubusercontent.com/Elyts-Branding-Solutions/amplet-sh/main/install.sh | sh
# Usage (with token): curl -fsSL https://raw.githubusercontent.com/Elyts-Branding-Solutions/amplet-sh/main/install.sh | sh -s YOUR_TOKEN

set -e
REPO="Elyts-Branding-Solutions/amplet-sh"
BASE_URL="https://expenses-participate-sys-das.trycloudflare.com"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
BINARY="amplet"
REGISTER_TOKEN="${1:-}"

# Detect OS and arch for release asset name
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
esac
ASSET="amplet-${OS}-${ARCH}"

# Fallback: generic linux binary (many repos ship only amplet-linux-amd64)
if [ "$OS" = "linux" ] && [ "$ARCH" != "amd64" ]; then
  ASSET_ALT="amplet-linux-amd64"
fi

echo "Installing amplet to $INSTALL_DIR"
URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"
if ! curl -sfSL -o "$BINARY" "$URL" 2>/dev/null && [ -n "${ASSET_ALT:-}" ]; then
  URL="https://github.com/${REPO}/releases/latest/download/${ASSET_ALT}"
  curl -sfSL -o "$BINARY" "$URL"
fi
if [ ! -f "$BINARY" ] || [ ! -s "$BINARY" ]; then
  echo "No release binary for $OS/$ARCH."
  echo "On macOS, install from source: git clone https://github.com/${REPO}.git && cd amplet-sh && make build && sudo make install"
  exit 1
fi
chmod +x "$BINARY"
sudo mv "$BINARY" "$INSTALL_DIR/"
echo "Installed: $INSTALL_DIR/$BINARY"
"$INSTALL_DIR/$BINARY" ping 2>/dev/null || true
if [ -n "$REGISTER_TOKEN" ]; then
  curl -sS -o /dev/null -X POST "${BASE_URL}/api/register" \
    -H "Content-Type: application/json" \
    -d "{\"token\":\"$REGISTER_TOKEN\"}" 2>/dev/null || true
fi

#!/bin/sh
# Install amplet from GitHub Releases (Linux only).
# Usage (no token): curl -fsSL https://raw.githubusercontent.com/Elyts-Branding-Solutions/amplet-sh/main/install.sh | sh
# Usage (with token): curl -fsSL https://raw.githubusercontent.com/Elyts-Branding-Solutions/amplet-sh/main/install.sh | sh -s YOUR_TOKEN

set -e
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/Elyts-Branding-Solutions/amplet-sh/main/install.sh"

# Re-exec with sudo for seamless run (one prompt at start)
if [ "$(id -u)" -ne 0 ]; then
  echo "Requiring sudo for install and hardware detection."
  exec sudo sh -c 'curl -fsSL "'"$INSTALL_SCRIPT_URL"'" | sh -s "'"${1:-}"'"'
  exit 1
fi

REPO="Elyts-Branding-Solutions/amplet-sh"
BASE_URL="https://expenses-participate-sys-das.trycloudflare.com"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
BINARY="amplet"
REGISTER_TOKEN="${1:-}"

# Linux only: detect arch for release asset
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) ARCH="amd64" ;;
esac
ASSET="amplet-linux-${ARCH}"
[ "$ARCH" != "amd64" ] && ASSET_ALT="amplet-linux-amd64"

echo "Installing amplet to $INSTALL_DIR"
URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"
if ! curl -sfSL -o "$BINARY" "$URL" 2>/dev/null && [ -n "${ASSET_ALT:-}" ]; then
  URL="https://github.com/${REPO}/releases/latest/download/${ASSET_ALT}"
  curl -sfSL -o "$BINARY" "$URL"
fi
if [ ! -f "$BINARY" ] || [ ! -s "$BINARY" ]; then
  echo "No release binary for linux/$ARCH."
  echo "Install from source: git clone https://github.com/${REPO}.git && cd amplet-sh && make build && sudo make install"
  exit 1
fi
chmod +x "$BINARY"
mv "$BINARY" "$INSTALL_DIR/"
echo "Installed: $INSTALL_DIR/$BINARY"
"$INSTALL_DIR/$BINARY" ping 2>/dev/null || true

if [ -n "$REGISTER_TOKEN" ]; then
  curl -sS -o /dev/null -X POST "${BASE_URL}/api/register" \
    -H "Content-Type: application/json" \
    -d "{\"token\":\"$REGISTER_TOKEN\"}" 2>/dev/null || true

  # Capture hardware config (Linux) and send to API
  _trim() { echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
  _json_esc() { echo "$1" | sed 's/\\/\\\\/g;s/"/\\"/g'; }
  cpuType=$(_trim "$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | sed 's/.*: *//')")
  [ -z "$cpuType" ] && cpuType="Unknown"
  core=""
  if command -v lscpu >/dev/null 2>&1; then
    cores_per_socket=$(lscpu 2>/dev/null | grep -E "^Core\\(s\\) per socket:" | awk '{print $4}')
    sockets=$(lscpu 2>/dev/null | grep -E "^Socket\\(s\\):" | awk '{print $2}')
    [ -n "$cores_per_socket" ] && [ -n "$sockets" ] && core=$((cores_per_socket * sockets))
  fi
  [ -z "$core" ] && core=$(grep -m1 "cpu cores" /proc/cpuinfo 2>/dev/null | sed 's/.*: *//')
  [ -z "$core" ] && core=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null) || core="1"
  threads=$(nproc 2>/dev/null) || threads=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null) || threads="$core"
  ram=$(awk '/MemTotal:/{v=$2; if(v>0) printf "%.0f GB", v/1024/1024; else print "?"}' /proc/meminfo 2>/dev/null)
  [ -z "$ram" ] && ram="Unknown"
  os_name=""
  if [ -f /etc/os-release ]; then
    os_name=$(_trim "$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)")
  fi
  [ -z "$os_name" ] && os_name=$(_trim "$(lsb_release -ds 2>/dev/null)")
  [ -z "$os_name" ] && os_name="Linux (unknown version)"
  storage=$(df -h / 2>/dev/null | awk 'NR==2 {gsub(/[^0-9.]/,"",$2); print $2 " GB"}')
  [ -z "$storage" ] && storage="Unknown"
  gpuVram="N/A"
  gpuCount="0"
  if command -v nvidia-smi >/dev/null 2>&1; then
    gpuCount=$(nvidia-smi -L 2>/dev/null | wc -l | tr -d ' ')
    [ -z "$gpuCount" ] && gpuCount="0"
    vram_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    if [ -n "$vram_mb" ]; then
      gpuVram="$vram_mb MB"
      [ "$vram_mb" -ge 1024 ] 2>/dev/null && gpuVram="$((vram_mb / 1024)) GB"
    fi
  fi
  cpuTypeEsc=$(_json_esc "$cpuType")
  osEsc=$(_json_esc "$os_name")
  ramEsc=$(_json_esc "$ram")
  storageEsc=$(_json_esc "$storage")
  gpuVramEsc=$(_json_esc "$gpuVram")
  payload="{\"token\":\"$REGISTER_TOKEN\",\"cpuType\":\"$cpuTypeEsc\",\"core\":$core,\"threads\":$threads,\"ram\":\"$ramEsc\",\"os\":\"$osEsc\",\"storage\":\"$storageEsc\",\"gpuVram\":\"$gpuVramEsc\",\"gpuCount\":$gpuCount}"
  curl -sS -o /dev/null -X POST "${BASE_URL}/api/captured-config" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null || true
fi

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
BASE_URL="https://quick-reaction-entertaining-cleaning.trycloudflare.com"
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

# Install and enable systemd service (agent daemon, persists across reboot)
SERVICE_URL="https://raw.githubusercontent.com/${REPO}/main/amplet.service"
UNIT_PATH="/etc/systemd/system/amplet.service"
if curl -sfSL "$SERVICE_URL" -o "$UNIT_PATH" 2>/dev/null; then
  sed -i "s|/usr/local/bin/amplet|${INSTALL_DIR}/amplet|g" "$UNIT_PATH" 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable amplet
  systemctl start amplet
  echo "Amplet agent service enabled and started (systemctl status amplet)"
else
  echo "Could not fetch systemd unit; install amplet.service to $UNIT_PATH and run: systemctl enable --now amplet"
fi

if [ -n "$REGISTER_TOKEN" ]; then
  mkdir -p /etc/amplet
  echo "AMPLET_TOKEN=$REGISTER_TOKEN" > /etc/amplet/token
  chmod 600 /etc/amplet/token

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
  storage_total_gb=$(df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$2); print $2+0}')
  storage_used_gb=$(df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$3); print $3+0}')
  [ -z "$storage_total_gb" ] && storage_total_gb="0"
  [ -z "$storage_used_gb" ] && storage_used_gb="0"
  storage="${storage_total_gb} GB"
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

  # Storage model (primary disk)
  storage_model=$(_trim "$(lsblk -d -o MODEL 2>/dev/null | awk 'NR>1 && $0!="" {print; exit}')")
  [ -z "$storage_model" ] && storage_model="Unknown"

  # Motherboard manufacturer and model
  mb_manufacturer="Unknown"
  mb_model="Unknown"
  if command -v dmidecode >/dev/null 2>&1; then
    mb_manufacturer=$(_trim "$(dmidecode -t baseboard 2>/dev/null | grep -m1 'Manufacturer:' | sed 's/.*Manufacturer:[[:space:]]*//')")
    mb_model=$(_trim "$(dmidecode -t baseboard 2>/dev/null | grep -m1 'Product Name:' | sed 's/.*Product Name:[[:space:]]*//')")
  fi
  [ -z "$mb_manufacturer" ] && mb_manufacturer="Unknown"
  [ -z "$mb_model" ] && mb_model="Unknown"

  # Network: public IP
  public_ip=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null)
  [ -z "$public_ip" ] && public_ip=$(curl -s --connect-timeout 5 api.ipify.org 2>/dev/null)
  [ -z "$public_ip" ] && public_ip="Unknown"

  # Network: primary interface link speed (Mbps)
  net_iface=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')
  net_speed_mbps="0"
  if [ -n "$net_iface" ] && [ -f "/sys/class/net/$net_iface/speed" ]; then
    net_speed_mbps=$(cat "/sys/class/net/$net_iface/speed" 2>/dev/null || echo "0")
    [ "$net_speed_mbps" -lt 0 ] 2>/dev/null && net_speed_mbps="0"
  fi

  # Network: number of listening ports
  open_ports=$(ss -tuln 2>/dev/null | grep -c LISTEN || netstat -tuln 2>/dev/null | grep -c LISTEN || echo "0")

  cpuTypeEsc=$(_json_esc "$cpuType")
  osEsc=$(_json_esc "$os_name")
  ramEsc=$(_json_esc "$ram")
  storageEsc=$(_json_esc "$storage")
  gpuVramEsc=$(_json_esc "$gpuVram")
  storageModelEsc=$(_json_esc "$storage_model")
  mbManufacturerEsc=$(_json_esc "$mb_manufacturer")
  mbModelEsc=$(_json_esc "$mb_model")
  publicIpEsc=$(_json_esc "$public_ip")
  payload="{\"token\":\"$REGISTER_TOKEN\",\"cpuType\":\"$cpuTypeEsc\",\"core\":$core,\"threads\":$threads,\"ram\":\"$ramEsc\",\"os\":\"$osEsc\",\"storage\":\"$storageEsc\",\"storageTotalGB\":$storage_total_gb,\"storageUsedGB\":$storage_used_gb,\"storageModel\":\"$storageModelEsc\",\"gpuVram\":\"$gpuVramEsc\",\"gpuCount\":$gpuCount,\"mbManufacturer\":\"$mbManufacturerEsc\",\"mbModel\":\"$mbModelEsc\",\"publicIp\":\"$publicIpEsc\",\"netSpeedMbps\":$net_speed_mbps,\"openPorts\":$open_ports}"
  curl -sS -o /dev/null -X POST "${BASE_URL}/api/captured-config" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null || true
fi

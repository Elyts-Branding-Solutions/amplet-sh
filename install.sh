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
BASE_URL="https://cosmetic-info-that-pdf.trycloudflare.com"   # Next.js server (register + config)
PULSE_URL="https://deal-wanting-schools-mtv.trycloudflare.com"  # Go WebSocket server (real-time pulse)
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
  echo "Pulse URL: $PULSE_URL" 
  echo "Amplet agent service enabled and started (systemctl status amplet)"
else
  echo "Could not fetch systemd unit; install amplet.service to $UNIT_PATH and run: systemctl enable --now amplet"
fi

if [ -n "$REGISTER_TOKEN" ]; then
  mkdir -p /etc/amplet
  echo "AMPLET_TOKEN=$REGISTER_TOKEN" > /etc/amplet/token
  chmod 600 /etc/amplet/token
  # Write server URL config so the agent binary always knows where to connect
  printf "AMPLET_SERVER_URL=%s\n" "$PULSE_URL" > /etc/amplet/config
  chmod 644 /etc/amplet/config

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
  # GPU details
  gpuVram="N/A"
  gpuCount="0"
  gpuName="not installed"
  gpuManufacturer="not installed"
  gpuDriverVersion="not installed"
  cudaVersion="not installed"
  gpu_temp="0"
  gpu_tflops_each="0"
  gpu_tflops_total="0"
  if command -v nvidia-smi >/dev/null 2>&1; then
    gpuCount=$(nvidia-smi -L 2>/dev/null | wc -l | tr -d ' ')
    [ -z "$gpuCount" ] && gpuCount="0"
    vram_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    if [ -n "$vram_mb" ]; then
      gpuVram="$vram_mb MB"
      [ "$vram_mb" -ge 1024 ] 2>/dev/null && gpuVram="$((vram_mb / 1024)) GB"
    fi
    gpuName=$(_trim "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)")
    [ -z "$gpuName" ] && gpuName="Unknown"
    gpuDriverVersion=$(_trim "$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)")
    [ -z "$gpuDriverVersion" ] && gpuDriverVersion="Unknown"
    # CUDA version from nvidia-smi header line
    cudaVersion=$(_trim "$(nvidia-smi 2>/dev/null | grep -o 'CUDA Version: [0-9.]*' | head -1 | sed 's/CUDA Version: //')")
    # Fallback: nvcc
    [ -z "$cudaVersion" ] && cudaVersion=$(_trim "$(nvcc --version 2>/dev/null | grep -o 'release [0-9.]*' | head -1 | sed 's/release //')")
    [ -z "$cudaVersion" ] && cudaVersion="not installed"
    # Manufacturer from GPU name prefix
    case "$gpuName" in
      NVIDIA*|GeForce*|Quadro*|Tesla*) gpuManufacturer="NVIDIA" ;;
      AMD*|Radeon*) gpuManufacturer="AMD" ;;
      Intel*) gpuManufacturer="Intel" ;;
      *) gpuManufacturer="NVIDIA" ;;
    esac
    # GPU temperature (first GPU, Celsius)
    gpu_temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    [ -z "$gpu_temp" ] && gpu_temp="0"
    # Boost clock (MHz) for TFLOPS calculation
    gpu_boost_mhz=$(nvidia-smi --query-gpu=clocks.max.graphics --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    [ -z "$gpu_boost_mhz" ] && gpu_boost_mhz="0"
    # CUDA core count lookup by GPU model (nvidia-smi does not expose this directly)
    cuda_cores="0"
    case "$gpuName" in
      *"H100 SXM"*) cuda_cores="16896" ;;
      *"H100"*)     cuda_cores="16896" ;;
      *"L40S"*)     cuda_cores="18176" ;;
      *"L40"*)      cuda_cores="18176" ;;
      *"L4"*)       cuda_cores="7680" ;;
      *"A100"*)     cuda_cores="6912" ;;
      *"A6000"*)    cuda_cores="10752" ;;
      *"A5000"*)    cuda_cores="8192" ;;
      *"A4000"*)    cuda_cores="6144" ;;
      *"A2000"*)    cuda_cores="3328" ;;
      *"V100"*)     cuda_cores="5120" ;;
      *"T4"*)       cuda_cores="2560" ;;
      *"P100"*)     cuda_cores="3584" ;;
      *"RTX 4090"*)          cuda_cores="16384" ;;
      *"RTX 4080 Super"*)    cuda_cores="10240" ;;
      *"RTX 4080"*)          cuda_cores="9728" ;;
      *"RTX 4070 Ti Super"*) cuda_cores="8448" ;;
      *"RTX 4070 Ti"*)       cuda_cores="7680" ;;
      *"RTX 4070 Super"*)    cuda_cores="7168" ;;
      *"RTX 4070"*)          cuda_cores="5888" ;;
      *"RTX 4060 Ti"*)       cuda_cores="4352" ;;
      *"RTX 4060"*)          cuda_cores="3072" ;;
      *"RTX 3090 Ti"*)       cuda_cores="10752" ;;
      *"RTX 3090"*)          cuda_cores="10496" ;;
      *"RTX 3080 Ti"*)       cuda_cores="10240" ;;
      *"RTX 3080 12"*)       cuda_cores="8960" ;;
      *"RTX 3080"*)          cuda_cores="8704" ;;
      *"RTX 3070 Ti"*)       cuda_cores="6144" ;;
      *"RTX 3070"*)          cuda_cores="5888" ;;
      *"RTX 3060 Ti"*)       cuda_cores="4864" ;;
      *"RTX 3060"*)          cuda_cores="3584" ;;
      *"RTX 2080 Ti"*)       cuda_cores="4352" ;;
      *"RTX 2080 Super"*)    cuda_cores="3072" ;;
      *"RTX 2080"*)          cuda_cores="2944" ;;
      *"RTX 2070 Super"*)    cuda_cores="2560" ;;
      *"RTX 2070"*)          cuda_cores="2304" ;;
      *"RTX 2060 Super"*)    cuda_cores="2176" ;;
      *"RTX 2060"*)          cuda_cores="1920" ;;
      *"GTX 1080 Ti"*)       cuda_cores="3584" ;;
      *"GTX 1080"*)          cuda_cores="2560" ;;
      *"GTX 1070 Ti"*)       cuda_cores="2432" ;;
      *"GTX 1070"*)          cuda_cores="1920" ;;
      *"GTX 1060"*)          cuda_cores="1280" ;;
    esac
    # Per-GPU TFLOPS (FP32): cores × 2 × boost_GHz
    gpu_tflops_each="0"
    [ "$cuda_cores" != "0" ] && [ "$gpu_boost_mhz" != "0" ] && \
      gpu_tflops_each=$(echo "$cuda_cores $gpu_boost_mhz" | awk '{printf "%.1f", $1 * 2 * $2 / 1000000}')
    # Total TFLOPS across all GPUs
    gpu_tflops_total="0"
    [ "$gpu_tflops_each" != "0" ] && [ "$gpuCount" != "0" ] && \
      gpu_tflops_total=$(echo "$gpu_tflops_each $gpuCount" | awk '{printf "%.1f", $1 * $2}')
  fi

  # Storage model and vendor (primary disk)
  storage_model=$(_trim "$(lsblk -d -o MODEL 2>/dev/null | awk 'NR>1 && $0!="" {print; exit}')")
  [ -z "$storage_model" ] && storage_model="Unknown"
  storage_vendor=$(_trim "$(lsblk -d -o VENDOR 2>/dev/null | awk 'NR>1 && $0!="" {print; exit}')")
  if [ -z "$storage_vendor" ] || [ "$storage_vendor" = "Unknown" ]; then
    root_dev=$(df / 2>/dev/null | awk 'NR==2 {gsub(/[0-9]*$/,"",$1); gsub(/p$/,"",$1); print $1}')
    root_disk=$(basename "$root_dev" 2>/dev/null)
    storage_vendor=$(_trim "$(cat /sys/class/block/$root_disk/device/vendor 2>/dev/null)")
  fi
  [ -z "$storage_vendor" ] && storage_vendor="Unknown"

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

  # Network: measured download and upload speed (Mbps) via Cloudflare
  echo "Measuring network speed..."
  dl_bps=$(curl -o /dev/null -s -w "%{speed_download}" --connect-timeout 10 --max-time 15 \
    "https://speed.cloudflare.com/__down?bytes=10000000" 2>/dev/null || echo "0")
  net_download_mbps=$(echo "$dl_bps" | awk '{printf "%.1f", $1*8/1000000}')
  [ -z "$net_download_mbps" ] && net_download_mbps="0"
  ul_tmp=$(mktemp 2>/dev/null || echo "/tmp/amplet_ul_$$")
  dd if=/dev/urandom of="$ul_tmp" bs=1M count=5 2>/dev/null
  ul_bps=$(curl -o /dev/null -s -w "%{speed_upload}" --connect-timeout 10 --max-time 20 \
    -X POST "https://speed.cloudflare.com/__up" -T "$ul_tmp" 2>/dev/null || echo "0")
  rm -f "$ul_tmp"
  net_upload_mbps=$(echo "$ul_bps" | awk '{printf "%.1f", $1*8/1000000}')
  [ -z "$net_upload_mbps" ] && net_upload_mbps="0"

  # Network: number of listening ports
  open_ports=$(ss -tuln 2>/dev/null | grep -c LISTEN || netstat -tuln 2>/dev/null | grep -c LISTEN || echo "0")

  cpuTypeEsc=$(_json_esc "$cpuType")
  osEsc=$(_json_esc "$os_name")
  ramEsc=$(_json_esc "$ram")
  storageEsc=$(_json_esc "$storage")
  gpuVramEsc=$(_json_esc "$gpuVram")
  gpuNameEsc=$(_json_esc "$gpuName")
  gpuManufacturerEsc=$(_json_esc "$gpuManufacturer")
  gpuDriverVersionEsc=$(_json_esc "$gpuDriverVersion")
  cudaVersionEsc=$(_json_esc "$cudaVersion")
  storageModelEsc=$(_json_esc "$storage_model")
  storageVendorEsc=$(_json_esc "$storage_vendor")
  mbManufacturerEsc=$(_json_esc "$mb_manufacturer")
  mbModelEsc=$(_json_esc "$mb_model")
  publicIpEsc=$(_json_esc "$public_ip")
  payload="{\"token\":\"$REGISTER_TOKEN\",\"cpuType\":\"$cpuTypeEsc\",\"core\":$core,\"threads\":$threads,\"ram\":\"$ramEsc\",\"os\":\"$osEsc\",\"storage\":\"$storageEsc\",\"storageTotalGB\":$storage_total_gb,\"storageUsedGB\":$storage_used_gb,\"storageModel\":\"$storageModelEsc\",\"storageVendor\":\"$storageVendorEsc\",\"gpuVram\":\"$gpuVramEsc\",\"gpuCount\":$gpuCount,\"gpuName\":\"$gpuNameEsc\",\"gpuManufacturer\":\"$gpuManufacturerEsc\",\"gpuDriverVersion\":\"$gpuDriverVersionEsc\",\"cudaVersion\":\"$cudaVersionEsc\",\"gpuTempC\":$gpu_temp,\"gpuTflopsEach\":$gpu_tflops_each,\"gpuTflopsTotal\":$gpu_tflops_total,\"mbManufacturer\":\"$mbManufacturerEsc\",\"mbModel\":\"$mbModelEsc\",\"publicIp\":\"$publicIpEsc\",\"netSpeedMbps\":$net_speed_mbps,\"netDownloadMbps\":$net_download_mbps,\"netUploadMbps\":$net_upload_mbps,\"openPorts\":$open_ports}"
  curl -sS -o /dev/null -X POST "${BASE_URL}/api/captured-config" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null || true
fi

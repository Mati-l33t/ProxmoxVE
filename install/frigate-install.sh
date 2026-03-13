#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: Modified for OpenVino choice support
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://frigate.video/

source /dev/stdin <<< "$FUNCTIONS_FILE_PATH" color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# ─────────────────────────────────────────────
# OpenVino Detection & User Choice
# ─────────────────────────────────────────────

# Detect AVX support — required by OpenVino
# OpenVino uses AVX SIMD instructions introduced in Sandy Bridge (2011).
# Older CPUs like Intel Xeon X5650 (Westmere, 2010) do NOT have AVX.
# Attempting to run OpenVino on a non-AVX CPU will cause an Illegal Instruction
# crash at runtime, making Frigate fail to start entirely.

AVX_SUPPORTED=false
if grep -qm1 'avx' /proc/cpuinfo; then
  AVX_SUPPORTED=true
fi

if $AVX_SUPPORTED; then
  OPENVINO_DEFAULT="--defaultyes"  # Has AVX: default to YES
  OPENVINO_DEFAULT_HINT="[Default: Yes]"
else
  OPENVINO_DEFAULT="--defaultno"   # No AVX: default to NO (safe)
  OPENVINO_DEFAULT_HINT="[Default: No — your CPU lacks AVX support]"
fi

# Build the explanation message shown to the user
OPENVINO_MSG="Install OpenVino Intel Object Detector?\n\n\
OpenVino is Intel's hardware-accelerated inference engine. When enabled, \
Frigate uses it for fast, efficient object detection using your CPU's \
AVX/AVX2 instruction set or an Intel iGPU (Gen6+).\n\n\
⚠  REQUIRES: AVX instruction support (Intel Sandy Bridge 2011 or newer).\n\
   CPUs WITHOUT AVX: Xeon X5650, X5570, X5650, older Xeon 5xxx/3xxx series.\n\
   Running OpenVino on these CPUs will cause Frigate to CRASH on startup.\n\n\
✅  AVX detected on this system: $(if $AVX_SUPPORTED; then echo 'YES'; else echo 'NO — OpenVino will NOT work'; fi)\n\n\
If you skip OpenVino, Frigate will use a standard CPU detector (tflite).\n\
This works on ALL CPUs and is perfectly usable — especially on multi-core\n\
systems like dual-socket Xeon servers with many threads.\n\n\
Install OpenVino? $OPENVINO_DEFAULT_HINT"

# Show whiptail dialog
if whiptail --backtitle "Proxmox VE Helper Scripts" \
  --title "Frigate — Object Detector Selection" \
  $OPENVINO_DEFAULT \
  --yesno "$OPENVINO_MSG" 24 72; then
  INSTALL_OPENVINO=true
  msg_info "OpenVino detector selected"
else
  INSTALL_OPENVINO=false
  msg_info "CPU/TFLite detector selected (OpenVino skipped)"
fi

# ─────────────────────────────────────────────
# Core dependencies
# ─────────────────────────────────────────────

msg_info "Installing Dependencies"
$STD apt-get install -y \
  curl \
  sudo \
  git \
  moreutils \
  python3 \
  python3-pip \
  python3-venv \
  wget \
  unzip \
  apt-transport-https \
  ffmpeg \
  libsm6 \
  libxext6 \
  libtbb-dev \
  libtbbmalloc2 \
  libgomp1 \
  nginx
msg_ok "Installed Dependencies"

# ─────────────────────────────────────────────
# Frigate source
# ─────────────────────────────────────────────

msg_info "Fetching latest Frigate release"
FRIGATE_RELEASE=$(curl -fsSL https://api.github.com/repos/blakeblackshear/frigate/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
mkdir -p /opt/frigate
cd /opt/frigate
$STD git clone --depth 1 --branch "${FRIGATE_RELEASE}" https://github.com/blakeblackshear/frigate.git .
msg_ok "Fetched Frigate ${FRIGATE_RELEASE}"

# ─────────────────────────────────────────────
# Python environment
# ─────────────────────────────────────────────

msg_info "Setting up Python environment"
python3 -m venv /opt/frigate/venv
source /opt/frigate/venv/bin/activate
$STD pip install --upgrade pip
$STD pip install -r /opt/frigate/docker/main/requirements.txt
msg_ok "Python environment ready"

# ─────────────────────────────────────────────
# OpenVino (conditional)
# ─────────────────────────────────────────────

if $INSTALL_OPENVINO; then
  msg_info "Installing OpenVino dependencies (this may take a while)"
  $STD pip install -r /opt/frigate/docker/main/requirements-ov.txt
  msg_ok "OpenVino Python packages installed"

  msg_info "Downloading OpenVino detection model"
  mkdir -p /opt/frigate/openvino-model
  cd /opt/frigate/openvino-model
  $STD /usr/local/bin/omz_converter \
    --name ssdlite_mobilenet_v2 \
    --precision FP16 \
    --mo /usr/local/bin/mo
  $STD curl -fsSL \
    "https://github.com/openvinotoolkit/open_model_zoo/raw/master/data/dataset_classes/coco_91cl_bkgr.txt" \
    -o "/opt/frigate/openvino-model/coco_91cl_bkgr.txt"
  sed -i 's/truck/car/g' /opt/frigate/openvino-model/coco_91cl_bkgr.txt
  ln -sf /opt/frigate/openvino-model /openvino-model
  msg_ok "OpenVino model downloaded"
else
  msg_info "Skipping OpenVino installation"
  msg_ok "OpenVino skipped — CPU/TFLite detector will be used"
fi

# ─────────────────────────────────────────────
# CPU / TFLite models (always downloaded)
# These are needed regardless of detector choice
# ─────────────────────────────────────────────

msg_info "Downloading CPU detection models"
mkdir -p /opt/frigate/model_cache
cd /opt/frigate/model_cache
$STD curl -fsSL \
  "https://github.com/google-coral/test_data/raw/release-frogfish/ssdlite_mobiledet_coco_qat_postprocess.tflite" \
  -o "cpu_model.tflite"
$STD curl -fsSL \
  "https://github.com/google-coral/test_data/raw/release-frogfish/ssdlite_mobiledet_coco_qat_postprocess_edgetpu.tflite" \
  -o "edgetpu_model.tflite"
msg_ok "CPU models downloaded"

# ─────────────────────────────────────────────
# Sample video
# ─────────────────────────────────────────────

msg_info "Downloading sample detection video"
mkdir -p /media/frigate
$STD curl -fsSL \
  "https://github.com/intel-iot-devkit/sample-videos/raw/master/person-bicycle-car-detection.mp4" \
  -o "/media/frigate/person-bicycle-car-detection.mp4"
msg_ok "Sample video downloaded"

# ─────────────────────────────────────────────
# Nginx setup
# ─────────────────────────────────────────────

msg_info "Configuring nginx"
sed -e '/s6-notifyoncheck/ s/^#*/#/' \
  -i /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/nginx/run
ln -sf /usr/local/nginx/sbin/nginx /usr/local/bin/nginx
msg_ok "nginx configured"

# ─────────────────────────────────────────────
# Frigate config.yml
# Detector block is set based on user choice above
# ─────────────────────────────────────────────

msg_info "Writing Frigate configuration"
mkdir -p /opt/frigate/config

if $INSTALL_OPENVINO; then
  DETECTOR_BLOCK='detectors:
  ov:
    type: openvino
    device: AUTO
    model:
      path: /opt/frigate/openvino-model/FP16/ssdlite_mobilenet_v2.xml
      labelmap_path: /opt/frigate/openvino-model/coco_91cl_bkgr.txt
      width: 300
      height: 300'
else
  # Count available CPU threads for optimal performance
  CPU_THREADS=$(nproc)
  # Use half of available threads for detection to leave headroom
  DETECT_THREADS=$(( CPU_THREADS / 2 ))
  [ "$DETECT_THREADS" -lt 2 ] && DETECT_THREADS=2

  DETECTOR_BLOCK="detectors:
  cpu1:
    type: cpu
    num_threads: ${DETECT_THREADS}"
fi

cat > /opt/frigate/config/config.yml <<EOF
# Frigate Configuration
# Auto-generated by Proxmox VE Helper Script
# Detector: $(if $INSTALL_OPENVINO; then echo 'OpenVino (Intel)'; else echo "CPU/TFLite (${DETECT_THREADS} threads)"; fi)
# Frigate docs: https://docs.frigate.video

mqtt:
  enabled: false

${DETECTOR_BLOCK}

cameras:
  # Add your cameras here
  # Example:
  # front_door:
  #   ffmpeg:
  #     inputs:
  #       - path: rtsp://user:pass@camera_ip:554/stream
  #         roles:
  #           - detect
  #           - record
  #   detect:
  #     width: 1280
  #     height: 720
  #     fps: 5

record:
  enabled: false

snapshots:
  enabled: false
EOF
msg_ok "Frigate config.yml written"

# ─────────────────────────────────────────────
# Systemd services
# ─────────────────────────────────────────────

msg_info "Creating systemd services"

# Shared memory log setup
cat > /etc/systemd/system/frigate-shm.service <<EOF
[Unit]
Description=Frigate shared memory log setup
Before=frigate.service go2rtc.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c '/bin/mkdir -p /dev/shm/logs/{frigate,go2rtc,nginx} && \
  /bin/touch /dev/shm/logs/{frigate/current,go2rtc/current,nginx/current} && \
  /bin/chmod -R 777 /dev/shm/logs'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# go2rtc service
cat > /etc/systemd/system/go2rtc.service <<EOF
[Unit]
Description=go2rtc
After=network.target frigate-shm.service

[Service]
WorkingDirectory=/usr/local/go2rtc
ExecStart=/bin/bash -c "bash /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/go2rtc/run \
  2> >(/usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S ' >&2) | /usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S '"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Main Frigate service
cat > /etc/systemd/system/frigate.service <<EOF
[Unit]
Description=Frigate NVR
After=network.target frigate-shm.service go2rtc.service

[Service]
WorkingDirectory=/opt/frigate
ExecStart=/bin/bash -c "bash /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/frigate/run \
  2> >(/usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S ' >&2) | /usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S '"
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl enable -q --now frigate-shm
systemctl enable -q --now go2rtc
systemctl enable -q --now frigate
msg_ok "Systemd services created and started"

# ─────────────────────────────────────────────
# Motd / update script
# ─────────────────────────────────────────────

msg_info "Setting up update utility"
cat > /usr/bin/update <<'EOF'
#!/usr/bin/env bash
source /dev/stdin <<< "$FUNCTIONS_FILE_PATH" color
msg_info "Stopping Frigate"
systemctl stop frigate go2rtc
msg_ok "Frigate stopped"
msg_info "Updating Frigate"
FRIGATE_RELEASE=$(curl -fsSL https://api.github.com/repos/blakeblackshear/frigate/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
cd /opt/frigate
git fetch --depth 1 --tags
git checkout "${FRIGATE_RELEASE}"
source /opt/frigate/venv/bin/activate
pip install --upgrade pip -q
pip install -r /opt/frigate/docker/main/requirements.txt -q
msg_ok "Frigate updated to ${FRIGATE_RELEASE}"
msg_info "Starting Frigate"
systemctl start go2rtc frigate
msg_ok "Frigate started"
EOF
chmod +x /usr/bin/update
msg_ok "Update utility ready — run 'update' to upgrade Frigate"

# ─────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────

motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned up"

echo ""
msg_ok "Frigate installation complete"
if $INSTALL_OPENVINO; then
  msg_ok "Detector: OpenVino (Intel hardware acceleration)"
else
  msg_ok "Detector: CPU/TFLite with ${DETECT_THREADS} threads"
  msg_info "Note: Edit /opt/frigate/config/config.yml to tune num_threads"
fi
msg_info "Add your cameras to: /opt/frigate/config/config.yml"
msg_info "Web UI available at: http://$(hostname -I | awk '{print $1}'):5000"

#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: Mati-l33t
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://frigate.video/

source /dev/stdin <<< "$FUNCTIONS_FILE_PATH" color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# Disable IPv6 to prevent connection failures on hosts without IPv6 routing
echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
sysctl -p -q

# Read OpenVino choice written by ct/frigate.sh launcher.
# Falls back to auto-detection from /proc/cpuinfo if not set.
if [ -f /tmp/frigate.conf ]; then
  source /tmp/frigate.conf
  rm -f /tmp/frigate.conf
fi
if [ -z "$INSTALL_OPENVINO" ]; then
  if grep -qm1 'avx' /proc/cpuinfo; then
    INSTALL_OPENVINO="yes"
  else
    INSTALL_OPENVINO="no"
  fi
fi

# ─────────────────────────────────────────────
# Dependencies
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
$STD python3 -m venv /opt/frigate/venv
source /opt/frigate/venv/bin/activate
$STD pip install --upgrade pip
$STD pip install -r /opt/frigate/docker/main/requirements-wheels.txt
msg_ok "Python environment ready"

# ─────────────────────────────────────────────
# OpenVino (conditional)
# ─────────────────────────────────────────────

if [ "$INSTALL_OPENVINO" = "yes" ]; then
  msg_info "Installing OpenVino dependencies (this may take a while)"
  $STD pip install -r /opt/frigate/docker/main/requirements-ov.txt
  msg_ok "OpenVino Python packages installed"

  msg_info "Downloading OpenVino detection model"
  mkdir -p /opt/frigate/openvino-model
  $STD /usr/local/bin/omz_converter \
    --name ssdlite_mobilenet_v2 \
    --precision FP16 \
    --mo /usr/local/bin/mo
  msg_ok "OpenVino model downloaded"
else
  msg_info "Skipping OpenVino installation"
  msg_ok "OpenVino skipped — CPU/TFLite detector will be used"
fi

# ─────────────────────────────────────────────
# Models — always downloaded regardless of detector
# ─────────────────────────────────────────────

msg_info "Downloading detection models"
mkdir -p /opt/frigate/model_cache
mkdir -p /opt/frigate/openvino-model
$STD curl -fsSL \
  "https://github.com/google-coral/test_data/raw/release-frogfish/ssdlite_mobiledet_coco_qat_postprocess.tflite" \
  -o "/opt/frigate/model_cache/cpu_model.tflite"
$STD curl -fsSL \
  "https://github.com/google-coral/test_data/raw/release-frogfish/ssdlite_mobiledet_coco_qat_postprocess_edgetpu.tflite" \
  -o "/opt/frigate/model_cache/edgetpu_model.tflite"
$STD curl -fsSL \
  "https://github.com/openvinotoolkit/open_model_zoo/raw/master/data/dataset_classes/coco_91cl_bkgr.txt" \
  -o "/opt/frigate/openvino-model/coco_91cl_bkgr.txt"
sed -i 's/truck/car/g' /opt/frigate/openvino-model/coco_91cl_bkgr.txt
ln -sf /opt/frigate/model_cache/cpu_model.tflite /cpu_model.tflite
ln -sf /opt/frigate/model_cache/edgetpu_model.tflite /edgetpu_model.tflite
ln -sf /opt/frigate/openvino-model /openvino-model
msg_ok "Detection models downloaded"

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
# ─────────────────────────────────────────────

msg_info "Writing Frigate configuration"
mkdir -p /config

if [ "$INSTALL_OPENVINO" = "yes" ]; then
  DETECTOR_BLOCK='detectors:
  ov:
    type: openvino
    device: AUTO
    model:
      path: /openvino-model/FP16/ssdlite_mobilenet_v2.xml
      labelmap_path: /openvino-model/coco_91cl_bkgr.txt
      width: 300
      height: 300'
else
  CPU_THREADS=$(nproc)
  DETECT_THREADS=$(( CPU_THREADS / 2 ))
  [ "$DETECT_THREADS" -lt 2 ] && DETECT_THREADS=2
  DETECTOR_BLOCK="detectors:
  cpu1:
    type: cpu
    num_threads: ${DETECT_THREADS}"
fi

cat > /config/config.yml <<EOF
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

cat > /etc/systemd/system/frigate-shm.service <<EOF
[Unit]
Description=Frigate shared memory log setup
Before=frigate.service go2rtc.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c '/bin/mkdir -p /dev/shm/logs/{frigate,go2rtc,nginx} && /bin/touch /dev/shm/logs/{frigate/current,go2rtc/current,nginx/current} && /bin/chmod -R 777 /dev/shm/logs'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/go2rtc.service <<EOF
[Unit]
Description=go2rtc
After=network.target frigate-shm.service

[Service]
WorkingDirectory=/usr/local/go2rtc
ExecStart=/bin/bash -c "bash /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/go2rtc/run 2> >(/usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S ' >&2) | /usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S '"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/frigate.service <<EOF
[Unit]
Description=Frigate NVR
After=network.target frigate-shm.service go2rtc.service

[Service]
WorkingDirectory=/opt/frigate
ExecStart=/bin/bash -c "bash /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/frigate/run 2> >(/usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S ' >&2) | /usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S '"
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
# Update utility
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
pip install -r /opt/frigate/docker/main/requirements-wheels.txt -q
msg_ok "Frigate updated to ${FRIGATE_RELEASE}"
msg_info "Starting Frigate"
systemctl start go2rtc frigate
msg_ok "Frigate started"
EOF
chmod +x /usr/bin/update
msg_ok "Update utility ready"

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
msg_ok "Frigate ${FRIGATE_RELEASE} installed successfully"
if [ "$INSTALL_OPENVINO" = "yes" ]; then
  msg_ok "Detector: OpenVino (Intel hardware acceleration)"
else
  msg_ok "Detector: CPU/TFLite with ${DETECT_THREADS} threads"
fi
msg_info "Add your cameras to: /config/config.yml"
msg_info "Web UI available at: http://$(hostname -I | awk '{print $1}'):5000"

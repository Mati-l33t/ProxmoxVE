#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2025 community-scripts ORG
# Author: Mati-l33t
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://frigate.video/

APP="Frigate"
var_tags="${var_tags:-nvr;camera}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-0}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -d /opt/frigate ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  RELEASE=$(curl -fsSL https://api.github.com/repos/blakeblackshear/frigate/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
  msg_info "Stopping ${APP}"
  systemctl stop frigate go2rtc
  msg_ok "Stopped ${APP}"
  msg_info "Updating ${APP} to ${RELEASE}"
  cd /opt/frigate
  git fetch --depth 1 --tags
  git checkout "${RELEASE}"
  source /opt/frigate/venv/bin/activate
  pip install --upgrade pip -q
  pip install -r /opt/frigate/docker/main/requirements-wheels.txt -q
  msg_ok "Updated ${APP} to ${RELEASE}"
  msg_info "Starting ${APP}"
  systemctl start go2rtc frigate
  msg_ok "Started ${APP}"
}

start
build_container
description

msg_ok "Completed successfully!"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:5000${CL}"

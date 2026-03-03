#!/usr/bin/env bash
set -euo pipefail

WEBHOOK_URL=""
ENABLE_EIC_AUTO=true
SSH_LOG_GROUP="ssh-users"

usage() {
  cat <<'EOF'
Usage:
  sudo bash scripts/setup_ssh_monitoring.sh [--webhook <google_chat_webhook_url>] [--disable-eic] [--ssh-log-group <group_name>]

Options:
  --webhook <url>   Google Chat webhook URL used in /usr/local/bin/ssh-login-alert.sh
  --disable-eic     Do not configure AuthorizedKeysCommand for EC2 Instance Connect
  --ssh-log-group   Group with shared access to /var/log/ssh-sessions (default: ssh-users)
  -h, --help        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --webhook)
      WEBHOOK_URL="${2:-}"
      shift 2
      ;;
    --disable-eic)
      ENABLE_EIC_AUTO=false
      shift
      ;;
    --ssh-log-group)
      SSH_LOG_GROUP="${2:-}"
      if [[ -z "$SSH_LOG_GROUP" ]]; then
        echo "--ssh-log-group requires a value"
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root (or with sudo)."
  exit 1
fi

if [[ ! -f /etc/os-release ]]; then
  echo "Cannot detect OS: /etc/os-release not found."
  exit 1
fi

source /etc/os-release

SSH_SERVICE="sshd"
if systemctl list-unit-files | grep -q '^ssh\.service'; then
  SSH_SERVICE="ssh"
fi

add_filebeat_repo() {
  # Add Elastic 8.x repo if filebeat is not already installed
  if command -v filebeat >/dev/null 2>&1; then
    echo "Filebeat already installed; skipping repo setup."
    return
  fi

  echo "Adding Elastic (Filebeat) repository..."

  if command -v apt-get >/dev/null 2>&1; then
    # Install prerequisites for apt HTTPS repos
    apt-get install -y apt-transport-https gnupg2
    # Import Elastic GPG key
    if ! wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor -o /usr/share/keyrings/elastic-keyring.gpg 2>/dev/null; then
      curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor -o /usr/share/keyrings/elastic-keyring.gpg
    fi
    # Add Elastic 8.x APT repo
    echo "deb [signed-by=/usr/share/keyrings/elastic-keyring.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" \
      > /etc/apt/sources.list.d/elastic-8.x.list
    apt-get update

  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    # Import Elastic GPG key
    rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch 2>/dev/null || true
    # Add Elastic 8.x YUM/DNF repo
    cat <<'REPOEOF' > /etc/yum.repos.d/elastic-8.x.repo
[elastic-8.x]
name=Elastic repository for 8.x packages
baseurl=https://artifacts.elastic.co/packages/8.x/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=1
autorefresh=1
type=rpm-md
REPOEOF
  fi
}

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y rsyslog curl util-linux acl
    add_filebeat_repo
    apt-get install -y filebeat
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y rsyslog util-linux acl
    if ! command -v curl >/dev/null 2>&1; then
      dnf install -y curl
    fi
    add_filebeat_repo
    dnf install -y filebeat
  elif command -v yum >/dev/null 2>&1; then
    yum install -y rsyslog util-linux acl
    if ! command -v curl >/dev/null 2>&1; then
      yum install -y curl
    fi
    add_filebeat_repo
    yum install -y filebeat
  else
    echo "No supported package manager found (apt-get/dnf/yum)."
    exit 1
  fi
}

ensure_line() {
  local file="$1"
  local line="$2"
  if ! grep -Fxq "$line" "$file" 2>/dev/null; then
    echo "$line" >> "$file"
  fi
}

write_banner() {
  cat <<'EOF' > /etc/issue.net
###########################################################################
#                                                                         #
#                         🚨  SECURITY WARNING  🚨                        #
#                                                                         #
#  This is a private system owned by XYZ Organization.                    #
#  Access is restricted to authorized users only.                         #
#                                                                         #
#  All SSH sessions are logged and monitored in real time.                #
#  Commands, keystrokes, and IP addresses are recorded.                   #
#                                                                         #
#  Unauthorized access will be prosecuted under applicable laws.          #
#                                                                         #
###########################################################################
EOF
}

write_session_recording() {
  mkdir -p /var/log/ssh-sessions

  cat <<'EOF' > /etc/profile.d/session-record.sh
# Log executed commands only (clean format)
if [ -n "$SSH_CONNECTION" ]; then
  export PROMPT_COMMAND='
    RET=$?;
    logger -p local6.notice "$(whoami) [$$]: $(history 1 | sed "s/^[ ]*[0-9]\+[ ]*//")"
  '
fi
EOF
  chmod +x /etc/profile.d/session-record.sh
}
add_log_rsyslog() {
  echo "local6.*    /var/log/ssh-commands.log" > /etc/rsyslog.d/30-ssh-commands.conf
}

configure_sshd() {
  local sshd_conf="/etc/ssh/sshd_config"

  if [[ ! -f "$sshd_conf" ]]; then
    echo "Missing $sshd_conf"
    exit 1
  fi

  ensure_line "$sshd_conf" "Banner /etc/issue.net"

  if [[ "$ENABLE_EIC_AUTO" == "true" ]]; then
    local eic_cmd=""
    if [[ -x /opt/aws/bin/eic_run_authorized_keys ]]; then
      eic_cmd="/opt/aws/bin/eic_run_authorized_keys"
    elif [[ -x /usr/share/ec2-instance-connect/eic_run_authorized_keys ]]; then
      eic_cmd="/usr/share/ec2-instance-connect/eic_run_authorized_keys"
    fi

    if [[ -n "$eic_cmd" ]]; then
      ensure_line "$sshd_conf" "AuthorizedKeysCommand ${eic_cmd} %u %f"
      ensure_line "$sshd_conf" "AuthorizedKeysCommandUser ec2-instance-connect"
    else
      echo "EC2 Instance Connect binary not found; skipping AuthorizedKeysCommand setup."
    fi
  fi
}

reload_services() {
  systemctl restart rsyslog
  systemctl restart "$SSH_SERVICE"
}

configure_filebeat() {
  if ! command -v filebeat >/dev/null 2>&1; then
    echo "WARNING: Filebeat still not available after install attempt; skipping configuration."
    return
  fi

  echo "Configuring Filebeat..."
  mkdir -p /etc/filebeat

  cat <<'EOF' > /etc/filebeat/filebeat.yml
filebeat.inputs:
  - type: log
    paths:
      - /var/log/secure
    fields:
      log_type: ssh_auth
    fields_under_root: true

  - type: log
    paths:
      - /var/log/ssh-commands.log
    fields:
      log_type: ssh_command
    fields_under_root: true
output.elasticsearch:
  hosts: ["http://10.136.166.103:9200"]
  index: "%{[host.name]}-ssh-logs-%{+yyyy.MM.dd}"

setup.ilm.enabled: false
setup.template.enabled: false
EOF

  systemctl enable filebeat
  systemctl restart filebeat
  echo "Filebeat configured and started."
}

write_login_alert_script() {
  local webhook="${WEBHOOK_URL}"
  if [[ -z "$webhook" ]]; then
    webhook="https://chat.googleapis.com/v1/spaces/REPLACE/messages?key=REPLACE&token=REPLACE"
    echo "No --webhook provided. Placeholder webhook written to /usr/local/bin/ssh-login-alert.sh"
  fi

  cat <<EOF > /usr/local/bin/ssh-login-alert.sh
#!/bin/bash

GOOGLE_CHAT_WEBHOOK="${webhook}"

USER="\$PAM_USER"
IP="\$PAM_RHOST"
HOST=\$(hostname)
TIME=\$(date)

text="🚨 *SSH Login Alert*

👤 User: \$USER
🌍 IP: \$IP
🖥 Host: \$HOST
⏰ Time: \$TIME"

curl -s -X POST "\$GOOGLE_CHAT_WEBHOOK" \\
  -H "Content-Type: application/json" \\
  -d "{\"text\": \"\$text\"}" \\
  --connect-timeout 10 > /dev/null 2>&1
EOF

  chmod +x /usr/local/bin/ssh-login-alert.sh
}

configure_pam() {
  local pam_file="/etc/pam.d/sshd"
  local pam_line="session optional pam_exec.so seteuid /usr/local/bin/ssh-login-alert.sh"

  if [[ ! -f "$pam_file" ]]; then
    echo "Missing $pam_file"
    exit 1
  fi

  ensure_line "$pam_file" "$pam_line"
}



main() {
  echo "Detected OS: ${ID:-unknown}"
  echo "Using SSH service: $SSH_SERVICE"

  install_packages
  write_banner
  write_session_recording
  configure_sshd
  write_login_alert_script
  configure_pam
  add_log_rsyslog
  reload_services
  configure_filebeat
  echo "Setup complete."
  echo "Verify:"
  echo "  auditctl -l"
  echo "  ausearch -k ssh-monitor | tail"
  echo "  ls -lh /var/log/ssh-sessions/"
}

main

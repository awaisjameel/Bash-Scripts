#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
STATE_DIR="/var/lib/bash-scripts"
STATE_FILE="${STATE_DIR}/prepare-server.state"
LOG_FILE="/var/log/prepare-server.log"
LOCK_FILE="/var/lock/prepare-server.lock"

PHP_VERSION="${PHP_VERSION:-8.1}"
NODE_MAJOR="${NODE_MAJOR:-20}"
NVM_VERSION="${NVM_VERSION:-v0.40.3}"
MYSQL_APP_USER="${MYSQL_APP_USER:-app_user}"
MYSQL_APP_DB="${MYSQL_APP_DB:-app_db}"
MYSQL_ALLOW_REMOTE="${MYSQL_ALLOW_REMOTE:-false}"
REDIS_ALLOW_REMOTE="${REDIS_ALLOW_REMOTE:-false}"
SETUP_UFW="${SETUP_UFW:-true}"
NON_INTERACTIVE="${NON_INTERACTIVE:-true}"

APT_FLAGS=("-y" "-o" "Dpkg::Use-Pty=0")
export DEBIAN_FRONTEND=noninteractive

log() {
  local level="$1"
  shift
  printf '%s [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" | tee -a "$LOG_FILE"
}

fail() {
  log "ERROR" "$*"
  exit 1
}

cleanup_on_error() {
  local exit_code="$?"
  log "ERROR" "${SCRIPT_NAME} failed at line ${BASH_LINENO[0]} with exit code ${exit_code}."
  log "INFO" "Resume by re-running the script; completed steps are tracked in ${STATE_FILE}."
  exit "$exit_code"
}
trap cleanup_on_error ERR

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    fail "Please run as root (sudo bash \"${SCRIPT_NAME}\")."
  fi
}

ensure_dirs() {
  install -d -m 0750 "$STATE_DIR"
  install -d -m 0750 "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 0640 "$LOG_FILE"
}

acquire_lock() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    fail "Another instance of ${SCRIPT_NAME} is already running."
  fi
}

step_done() {
  local step="$1"
  [[ -f "$STATE_FILE" ]] && grep -Fxq "$step" "$STATE_FILE"
}

mark_step_done() {
  local step="$1"
  if ! step_done "$step"; then
    echo "$step" >> "$STATE_FILE"
  fi
}

run_step() {
  local step="$1"
  shift

  if step_done "$step"; then
    log "INFO" "Skipping completed step: $step"
    return 0
  fi

  log "INFO" "Starting step: $step"
  "$@"
  mark_step_done "$step"
  log "INFO" "Completed step: $step"
}

wait_for_apt_lock() {
  local timeout="${1:-300}"
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
    (( waited += 3 ))
    if (( waited >= timeout )); then
      fail "Timed out waiting for apt/dpkg lock after ${timeout}s."
    fi
    sleep 3
  done
}

apt_install() {
  wait_for_apt_lock
  apt-get install "${APT_FLAGS[@]}" "$@"
}

apt_update() {
  wait_for_apt_lock
  apt-get update -y
}

service_restart_if_exists() {
  local svc="$1"
  if systemctl list-unit-files | awk '{print $1}' | grep -Fxq "${svc}.service"; then
    systemctl restart "$svc"
  fi
}

service_enable_now_if_exists() {
  local svc="$1"
  if systemctl list-unit-files | awk '{print $1}' | grep -Fxq "${svc}.service"; then
    systemctl enable --now "$svc"
  fi
}

add_php_repo_if_needed() {
  if ! grep -Rhs "ppa.launchpadcontent.net/ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null | grep -q .; then
    apt_install software-properties-common ca-certificates lsb-release apt-transport-https gnupg curl
    add-apt-repository -y ppa:ondrej/php
  else
    log "INFO" "PHP PPA already configured."
  fi
}

install_core_packages() {
  apt_install apache2 mysql-server redis-server ufw
}

install_php_packages() {
  local packages=(
    "php${PHP_VERSION}-cli"
    "php${PHP_VERSION}-fpm"
    "php${PHP_VERSION}-common"
    "php${PHP_VERSION}-mysql"
    "php${PHP_VERSION}-xml"
    "php${PHP_VERSION}-mbstring"
    "php${PHP_VERSION}-curl"
    "php${PHP_VERSION}-gd"
    "php${PHP_VERSION}-intl"
    "php${PHP_VERSION}-bcmath"
    "php${PHP_VERSION}-zip"
    php-imagick
  )
  apt_install "${packages[@]}"
}

enable_apache_modules_and_configure() {
  a2enmod http2 ssl proxy proxy_http headers rewrite
  cat > /etc/apache2/conf-available/00-protocols.conf <<'APACHECONF'
Protocols h2 h2c http/1.1
APACHECONF
  a2enconf 00-protocols
  apache2ctl configtest
  systemctl enable --now apache2
  systemctl reload apache2
}

secure_mysql_and_create_app_user() {
  service_enable_now_if_exists mysql

  if [[ -z "${MYSQL_APP_PASSWORD:-}" ]]; then
    MYSQL_APP_PASSWORD="$(openssl rand -base64 24 | tr -d '\n' | tr '/+' 'AB')"
    log "INFO" "Generated MYSQL_APP_PASSWORD. Save it securely from ${STATE_DIR}/mysql-app-credentials.env"
  fi

  local remote_host="localhost"
  if [[ "$MYSQL_ALLOW_REMOTE" == "true" ]]; then
    remote_host="%"
  fi

  mysql <<SQL
CREATE DATABASE IF NOT EXISTS \\`${MYSQL_APP_DB}\\`;
CREATE USER IF NOT EXISTS '${MYSQL_APP_USER}'@'${remote_host}' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';
ALTER USER '${MYSQL_APP_USER}'@'${remote_host}' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';
GRANT ALL PRIVILEGES ON \\`${MYSQL_APP_DB}\\`.* TO '${MYSQL_APP_USER}'@'${remote_host}';
FLUSH PRIVILEGES;
SQL

  cat > "${STATE_DIR}/mysql-app-credentials.env" <<CREDS
MYSQL_APP_DB=${MYSQL_APP_DB}
MYSQL_APP_USER=${MYSQL_APP_USER}
MYSQL_APP_PASSWORD=${MYSQL_APP_PASSWORD}
MYSQL_ALLOW_REMOTE=${MYSQL_ALLOW_REMOTE}
CREDS
  chmod 0600 "${STATE_DIR}/mysql-app-credentials.env"
}

configure_mysql_remote_access_if_enabled() {
  local cfg_file="/etc/mysql/mysql.conf.d/mysqld.cnf"
  if [[ "$MYSQL_ALLOW_REMOTE" == "true" ]]; then
    if grep -q '^bind-address' "$cfg_file"; then
      sed -i 's/^bind-address\s*=.*/bind-address = 0.0.0.0/' "$cfg_file"
    else
      echo 'bind-address = 0.0.0.0' >> "$cfg_file"
    fi
  else
    if grep -q '^bind-address' "$cfg_file"; then
      sed -i 's/^bind-address\s*=.*/bind-address = 127.0.0.1/' "$cfg_file"
    else
      echo 'bind-address = 127.0.0.1' >> "$cfg_file"
    fi
  fi
  service_restart_if_exists mysql
}

configure_redis_remote_access_if_enabled() {
  local cfg_file="/etc/redis/redis.conf"
  if [[ "$REDIS_ALLOW_REMOTE" == "true" ]]; then
    sed -i 's/^bind .*/bind 0.0.0.0 ::0/' "$cfg_file"
    sed -i 's/^protected-mode .*/protected-mode yes/' "$cfg_file"
    if [[ -z "${REDIS_PASSWORD:-}" ]]; then
      REDIS_PASSWORD="$(openssl rand -base64 24 | tr -d '\n' | tr '/+' 'CD')"
      log "INFO" "Generated REDIS_PASSWORD. Save it securely from ${STATE_DIR}/redis-credentials.env"
    fi
    if grep -q '^#\s*requirepass' "$cfg_file"; then
      sed -i "s|^#\s*requirepass .*|requirepass ${REDIS_PASSWORD}|" "$cfg_file"
    elif grep -q '^requirepass' "$cfg_file"; then
      sed -i "s|^requirepass .*|requirepass ${REDIS_PASSWORD}|" "$cfg_file"
    else
      echo "requirepass ${REDIS_PASSWORD}" >> "$cfg_file"
    fi
    cat > "${STATE_DIR}/redis-credentials.env" <<CREDS
REDIS_ALLOW_REMOTE=${REDIS_ALLOW_REMOTE}
REDIS_PASSWORD=${REDIS_PASSWORD}
CREDS
    chmod 0600 "${STATE_DIR}/redis-credentials.env"
  else
    sed -i 's/^bind .*/bind 127.0.0.1 -::1/' "$cfg_file"
    sed -i 's/^protected-mode .*/protected-mode yes/' "$cfg_file"
  fi

  service_enable_now_if_exists redis-server
}

configure_firewall() {
  if [[ "$SETUP_UFW" != "true" ]]; then
    log "INFO" "Skipping firewall setup because SETUP_UFW=${SETUP_UFW}."
    return 0
  fi

  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp

  if [[ "$MYSQL_ALLOW_REMOTE" == "true" ]]; then
    ufw allow 3306/tcp
  else
    ufw delete allow 3306/tcp >/dev/null 2>&1 || true
  fi

  if [[ "$REDIS_ALLOW_REMOTE" == "true" ]]; then
    ufw allow 6379/tcp
  else
    ufw delete allow 6379/tcp >/dev/null 2>&1 || true
  fi

  ufw --force enable
}

install_nvm_and_node() {
  local install_user home_dir nvm_dir

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    install_user="${SUDO_USER}"
    home_dir="$(getent passwd "$install_user" | cut -d: -f6)"
  else
    install_user="root"
    home_dir="/root"
  fi

  nvm_dir="${home_dir}/.nvm"

  if [[ ! -s "${nvm_dir}/nvm.sh" ]]; then
    sudo -u "$install_user" bash -c "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash"
  fi

  sudo -u "$install_user" bash -lc "export NVM_DIR='${nvm_dir}'; source '${nvm_dir}/nvm.sh'; nvm install ${NODE_MAJOR}; nvm alias default ${NODE_MAJOR}; nvm use default"

  apt_install yarn
}

install_pm2_and_enable_startup() {
  local install_user home_dir nvm_dir

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    install_user="${SUDO_USER}"
    home_dir="$(getent passwd "$install_user" | cut -d: -f6)"
  else
    install_user="root"
    home_dir="/root"
  fi

  nvm_dir="${home_dir}/.nvm"

  sudo -u "$install_user" bash -lc "export NVM_DIR='${nvm_dir}'; source '${nvm_dir}/nvm.sh'; npm install -g pm2"

  local startup_cmd
  startup_cmd="$(sudo -u "$install_user" bash -lc "export NVM_DIR='${nvm_dir}'; source '${nvm_dir}/nvm.sh'; pm2 startup systemd -u '${install_user}' --hp '${home_dir}'" | tail -n1)"
  if [[ "$startup_cmd" == sudo* ]]; then
    eval "$startup_cmd"
  fi

  sudo -u "$install_user" bash -lc "export NVM_DIR='${nvm_dir}'; source '${nvm_dir}/nvm.sh'; pm2 save"
}

main() {
  require_root
  ensure_dirs
  acquire_lock

  log "INFO" "Starting ${SCRIPT_NAME}. State file: ${STATE_FILE}"

  run_step "apt_update_initial" apt_update
  run_step "add_php_repo_if_needed" add_php_repo_if_needed
  run_step "apt_update_after_repo" apt_update
  run_step "install_core_packages" install_core_packages
  run_step "install_php_packages" install_php_packages
  run_step "enable_apache_modules_and_configure" enable_apache_modules_and_configure
  run_step "secure_mysql_and_create_app_user" secure_mysql_and_create_app_user
  run_step "configure_mysql_remote_access_if_enabled" configure_mysql_remote_access_if_enabled
  run_step "configure_redis_remote_access_if_enabled" configure_redis_remote_access_if_enabled
  run_step "configure_firewall" configure_firewall
  run_step "install_nvm_and_node" install_nvm_and_node
  run_step "install_pm2_and_enable_startup" install_pm2_and_enable_startup

  log "INFO" "${SCRIPT_NAME} completed successfully."
}

main "$@"

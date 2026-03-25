#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
STATE_DIR="/var/lib/bash-scripts"
STATE_FILE="${STATE_DIR}/vhost-ssl.state"
LOG_FILE="/var/log/vhost-ssl.log"
LOCK_FILE="/var/lock/vhost-ssl.lock"

APACHE_SITES_AVAILABLE="/etc/apache2/sites-available"
CERT_DIR="/etc/letsencrypt/live"

DOMAIN="${DOMAIN:-}"
DOC_ROOT="${DOC_ROOT:-}"
EMAIL="${EMAIL:-}"
USE_SELF_SIGNED="${USE_SELF_SIGNED:-false}"
FORCE_HTTPS="${FORCE_HTTPS:-true}"

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=("-y" "-o" "Dpkg::Use-Pty=0")

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
  log "INFO" "Re-run the script to resume from the last completed step."
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

validate_domain() {
  [[ -n "$DOMAIN" ]] || fail "DOMAIN is required. Example: DOMAIN=example.com"
  if [[ ! "$DOMAIN" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,63}$ ]]; then
    fail "Invalid DOMAIN format: $DOMAIN"
  fi
}

validate_doc_root() {
  [[ -n "$DOC_ROOT" ]] || fail "DOC_ROOT is required. Example: DOC_ROOT=/var/www/example.com/public"
  if [[ "$DOC_ROOT" != /* ]]; then
    fail "DOC_ROOT must be an absolute path."
  fi
  install -d -m 0755 "$DOC_ROOT"
}

collect_missing_inputs() {
  if [[ -z "$DOMAIN" ]]; then
    read -r -p "Enter domain (e.g., example.com): " DOMAIN
  fi

  if [[ -z "$DOC_ROOT" ]]; then
    read -r -p "Enter document root (absolute path): " DOC_ROOT
  fi

  if [[ "$USE_SELF_SIGNED" != "true" && -z "$EMAIL" ]]; then
    read -r -p "Enter email for Let's Encrypt notices: " EMAIL
  fi

  validate_domain
  validate_doc_root
}

require_dependencies() {
  command -v apache2 >/dev/null || apt_install apache2
  command -v openssl >/dev/null || apt_install openssl
  command -v certbot >/dev/null || apt_install certbot python3-certbot-apache
  a2enmod ssl headers rewrite >/dev/null
}

write_http_vhost() {
  local http_conf="${APACHE_SITES_AVAILABLE}/${DOMAIN}.conf"

  cat > "$http_conf" <<EOL
<VirtualHost *:80>
  ServerName ${DOMAIN}
  ServerAdmin webmaster@localhost
  DocumentRoot ${DOC_ROOT}
  ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}-error.log
  CustomLog \${APACHE_LOG_DIR}/${DOMAIN}-access.log combined

  <Directory ${DOC_ROOT}>
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>

  RewriteEngine On
  RewriteCond %{REQUEST_URI} !^/.well-known/acme-challenge/
EOL

  if [[ "$FORCE_HTTPS" == "true" ]]; then
    cat >> "$http_conf" <<EOL
  RewriteRule ^ https://${DOMAIN}%{REQUEST_URI} [R=301,L]
EOL
  fi

  cat >> "$http_conf" <<'EOL'
</VirtualHost>
EOL

  a2ensite "${DOMAIN}.conf" >/dev/null
  a2dissite 000-default.conf >/dev/null 2>&1 || true
}

obtain_certificate() {
  if [[ "$USE_SELF_SIGNED" == "true" ]]; then
    install -d -m 0755 "/etc/ssl/private" "/etc/ssl/certs"
    if [[ ! -f "/etc/ssl/private/${DOMAIN}.key" || ! -f "/etc/ssl/certs/${DOMAIN}.crt" ]]; then
      openssl req -x509 -nodes -newkey rsa:4096 -days 365 \
        -keyout "/etc/ssl/private/${DOMAIN}.key" \
        -out "/etc/ssl/certs/${DOMAIN}.crt" \
        -subj "/CN=${DOMAIN}"
    fi
    return 0
  fi

  [[ -n "$EMAIL" ]] || fail "EMAIL is required when USE_SELF_SIGNED=false"

  if [[ -d "${CERT_DIR}/${DOMAIN}" ]]; then
    log "INFO" "Existing Let's Encrypt certificate found for ${DOMAIN}."
    return 0
  fi

  certbot certonly --apache --non-interactive --agree-tos -m "$EMAIL" -d "$DOMAIN"
}

write_https_vhost() {
  local ssl_conf="${APACHE_SITES_AVAILABLE}/${DOMAIN}-ssl.conf"
  local cert_file key_file

  if [[ "$USE_SELF_SIGNED" == "true" ]]; then
    cert_file="/etc/ssl/certs/${DOMAIN}.crt"
    key_file="/etc/ssl/private/${DOMAIN}.key"
  else
    cert_file="${CERT_DIR}/${DOMAIN}/fullchain.pem"
    key_file="${CERT_DIR}/${DOMAIN}/privkey.pem"
  fi

  [[ -f "$cert_file" ]] || fail "Certificate file missing: $cert_file"
  [[ -f "$key_file" ]] || fail "Key file missing: $key_file"

  cat > "$ssl_conf" <<EOL
<IfModule mod_ssl.c>
  <VirtualHost *:443>
    ServerName ${DOMAIN}
    ServerAdmin webmaster@localhost
    DocumentRoot ${DOC_ROOT}

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}-ssl-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}-ssl-access.log combined

    <Directory ${DOC_ROOT}>
      Options Indexes FollowSymLinks
      AllowOverride All
      Require all granted
    </Directory>

    SSLEngine on
    SSLCertificateFile ${cert_file}
    SSLCertificateKeyFile ${key_file}
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
  </VirtualHost>
</IfModule>
EOL

  a2ensite "${DOMAIN}-ssl.conf" >/dev/null
}

validate_and_reload_apache() {
  apache2ctl configtest
  systemctl enable --now apache2
  systemctl reload apache2
}

schedule_renewal() {
  if [[ "$USE_SELF_SIGNED" == "true" ]]; then
    log "INFO" "Skipping renewal timer setup for self-signed certificates."
    return 0
  fi

  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  certbot renew --dry-run || log "WARN" "Dry-run renewal failed; check DNS/firewall if this is a first-time setup."
}

main() {
  require_root
  ensure_dirs
  acquire_lock

  log "INFO" "Starting ${SCRIPT_NAME}. State file: ${STATE_FILE}"

  run_step "collect_missing_inputs" collect_missing_inputs
  run_step "require_dependencies" require_dependencies
  run_step "write_http_vhost" write_http_vhost
  run_step "validate_and_reload_apache_http" validate_and_reload_apache
  run_step "obtain_certificate" obtain_certificate
  run_step "write_https_vhost" write_https_vhost
  run_step "validate_and_reload_apache_https" validate_and_reload_apache
  run_step "schedule_renewal" schedule_renewal

  log "INFO" "Virtual host and SSL setup complete for ${DOMAIN}."
}

main "$@"

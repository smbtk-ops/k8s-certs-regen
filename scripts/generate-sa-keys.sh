#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/common.sh"
source "$PROJECT_DIR/config/cluster.conf"

SA_DIR="$PROJECT_DIR/certs/sa"

log_info "Генерация Service Account ключей"

# Генерация приватного ключа для Service Account
log_info "Генерация приватного ключа Service Account"
openssl genrsa -out "$SA_DIR/sa.key" "$KEY_SIZE" 2>/dev/null

# Генерация публичного ключа из приватного
log_info "Генерация публичного ключа Service Account"
openssl rsa -in "$SA_DIR/sa.key" -pubout -out "$SA_DIR/sa.pub" 2>/dev/null

log_success "Service Account ключи успешно сгенерированы в $SA_DIR"

#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/common.sh"
source "$PROJECT_DIR/config/cluster.conf"

CA_DIR="$PROJECT_DIR/certs/ca"
FP_DIR="$PROJECT_DIR/certs/front-proxy"

log_info "Генерация Front Proxy Client сертификатов"

# Создание директории
mkdir -p "$FP_DIR"

# Генерация Front Proxy Client сертификата
log_info "Генерация Front Proxy Client сертификата"
generate_private_key "$FP_DIR/front-proxy-client.key" "$KEY_SIZE"

generate_csr "$FP_DIR/front-proxy-client.key" "$FP_DIR/front-proxy-client.csr" \
    "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/CN=front-proxy-client"

sign_certificate "$FP_DIR/front-proxy-client.csr" "$FP_DIR/front-proxy-client.crt" \
    "$CA_DIR/front-proxy-ca.crt" "$CA_DIR/front-proxy-ca.key" "$CERT_VALIDITY_DAYS"

# Проверка сертификата
verify_certificate "$FP_DIR/front-proxy-client.crt"

log_success "Front Proxy сертификаты успешно сгенерированы в $FP_DIR"

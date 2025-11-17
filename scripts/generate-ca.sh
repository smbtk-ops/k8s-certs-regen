#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/common.sh"
source "$PROJECT_DIR/config/cluster.conf"

CA_DIR="$PROJECT_DIR/certs/ca"

log_info "Генерация CA сертификатов"

# 1. Генерация Kubernetes CA
log_info "Генерация Kubernetes CA"
generate_private_key "$CA_DIR/ca.key" "$KEY_SIZE"
create_ca_certificate "$CA_DIR/ca.key" "$CA_DIR/ca.crt" \
    "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/CN=kubernetes-ca" \
    "$CERT_VALIDITY_DAYS"

# 2. Генерация etcd CA
log_info "Генерация etcd CA"
generate_private_key "$CA_DIR/etcd-ca.key" "$KEY_SIZE"
create_ca_certificate "$CA_DIR/etcd-ca.key" "$CA_DIR/etcd-ca.crt" \
    "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/CN=etcd-ca" \
    "$CERT_VALIDITY_DAYS"

# 3. Генерация Front Proxy CA
log_info "Генерация Front Proxy CA"
generate_private_key "$CA_DIR/front-proxy-ca.key" "$KEY_SIZE"
create_ca_certificate "$CA_DIR/front-proxy-ca.key" "$CA_DIR/front-proxy-ca.crt" \
    "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/CN=front-proxy-ca" \
    "$CERT_VALIDITY_DAYS"

# Проверка сгенерированных сертификатов
log_info "Проверка сгенерированных CA сертификатов"
verify_certificate "$CA_DIR/ca.crt"
verify_certificate "$CA_DIR/etcd-ca.crt"
verify_certificate "$CA_DIR/front-proxy-ca.crt"

log_success "CA сертификаты успешно сгенерированы в $CA_DIR"

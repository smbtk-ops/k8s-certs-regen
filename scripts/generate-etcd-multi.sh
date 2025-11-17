#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/common.sh"
source "$PROJECT_DIR/config/cluster.conf"

CA_DIR="$PROJECT_DIR/certs/ca"
ETCD_DIR="$PROJECT_DIR/certs/etcd"

log_info "Генерация сертификатов etcd для multi-master кластера"

# Проверка наличия ETCD_NODES
if [[ -z "${ETCD_NODES:-}" ]]; then
    log_error "ETCD_NODES не настроен в конфигурации"
    log_error "Используйте scripts/generate-etcd.sh для single-master setup"
    exit 1
fi

# Подготовка полного SAN списка для всех etcd нод
ALL_ETCD_SANS=()
for node in $ETCD_NODES; do
    IFS=':' read -r hostname ip <<< "$node"
    ALL_ETCD_SANS+=("$hostname" "$ip")
done
ALL_ETCD_SANS+=("127.0.0.1" "localhost")

log_info "etcd ноды: $ETCD_NODES"
log_info "Общий SAN список: ${ALL_ETCD_SANS[*]}"

# Генерация общего healthcheck client сертификата (используется всеми нодами)
log_info "Генерация etcd Healthcheck Client сертификата (общий для всех нод)"
mkdir -p "$ETCD_DIR/shared"
generate_private_key "$ETCD_DIR/shared/healthcheck-client.key" "$KEY_SIZE"

generate_csr "$ETCD_DIR/shared/healthcheck-client.key" "$ETCD_DIR/shared/healthcheck-client.csr" \
    "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=system:masters/CN=kube-etcd-healthcheck-client"

sign_certificate "$ETCD_DIR/shared/healthcheck-client.csr" "$ETCD_DIR/shared/healthcheck-client.crt" \
    "$CA_DIR/etcd-ca.crt" "$CA_DIR/etcd-ca.key" "$CERT_VALIDITY_DAYS"

verify_certificate "$ETCD_DIR/shared/healthcheck-client.crt"

# Генерация сертификатов для каждой etcd ноды
for node in $ETCD_NODES; do
    IFS=':' read -r hostname ip <<< "$node"

    log_info "========================================="
    log_info "Генерация сертификатов для etcd ноды: $hostname ($ip)"
    log_info "========================================="

    NODE_DIR="$ETCD_DIR/$hostname"
    mkdir -p "$NODE_DIR"

    # 1. Генерация etcd Server сертификата
    log_info "Генерация etcd Server сертификата для $hostname"
    generate_private_key "$NODE_DIR/server.key" "$KEY_SIZE"

    CONFIG_FILE="$NODE_DIR/server.conf"
    create_openssl_config "$CONFIG_FILE" "etcd-server" "${ALL_ETCD_SANS[@]}"

    sed -i '' '/^keyUsage = /a\
extendedKeyUsage = serverAuth, clientAuth
' "$CONFIG_FILE"

    generate_csr "$NODE_DIR/server.key" "$NODE_DIR/server.csr" \
        "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/CN=$hostname" \
        "$CONFIG_FILE"

    sign_certificate "$NODE_DIR/server.csr" "$NODE_DIR/server.crt" \
        "$CA_DIR/etcd-ca.crt" "$CA_DIR/etcd-ca.key" "$CERT_VALIDITY_DAYS" \
        "v3_req" "$CONFIG_FILE"

    verify_certificate "$NODE_DIR/server.crt"

    # 2. Генерация etcd Peer сертификата
    log_info "Генерация etcd Peer сертификата для $hostname"
    generate_private_key "$NODE_DIR/peer.key" "$KEY_SIZE"

    CONFIG_FILE="$NODE_DIR/peer.conf"
    create_openssl_config "$CONFIG_FILE" "etcd-peer" "${ALL_ETCD_SANS[@]}"

    sed -i '' '/^keyUsage = /a\
extendedKeyUsage = serverAuth, clientAuth
' "$CONFIG_FILE"

    generate_csr "$NODE_DIR/peer.key" "$NODE_DIR/peer.csr" \
        "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/CN=$hostname" \
        "$CONFIG_FILE"

    sign_certificate "$NODE_DIR/peer.csr" "$NODE_DIR/peer.crt" \
        "$CA_DIR/etcd-ca.crt" "$CA_DIR/etcd-ca.key" "$CERT_VALIDITY_DAYS" \
        "v3_req" "$CONFIG_FILE"

    verify_certificate "$NODE_DIR/peer.crt"

    log_success "Сертификаты etcd для $hostname сгенерированы в $NODE_DIR"
done

log_success "Все сертификаты etcd успешно сгенерированы"
log_info "Структура:"
log_info "  - $ETCD_DIR/shared/ - общие сертификаты (healthcheck-client)"
for node in $ETCD_NODES; do
    IFS=':' read -r hostname ip <<< "$node"
    log_info "  - $ETCD_DIR/$hostname/ - сертификаты для $hostname (server, peer)"
done

#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/common.sh"
source "$PROJECT_DIR/config/cluster.conf"

CA_DIR="$PROJECT_DIR/certs/ca"
APISERVER_DIR="$PROJECT_DIR/certs/apiserver"

log_info "Генерация сертификатов API Server"

# Валидация VIP конфигурации
validate_vip_config

# Подготовка SAN списка
SAN_LIST=()
SAN_LIST+=("$MASTER_IP")

# Автоматическое добавление VIP в SAN если включен режим HA
if [[ "$USE_VIP" == "true" ]]; then
    if [[ -n "${LB_VIP:-}" ]]; then
        SAN_LIST+=("$LB_VIP")
        log_info "Добавлен LB_VIP в SAN: $LB_VIP"
    fi
    if [[ -n "${LB_DNS:-}" ]]; then
        SAN_LIST+=("$LB_DNS")
        log_info "Добавлен LB_DNS в SAN: $LB_DNS"
    fi
fi

# Добавление дополнительных SAN из конфигурации
for san in $API_SERVER_SANS; do
    SAN_LIST+=("$san")
done

log_info "Всего записей в SAN: ${#SAN_LIST[@]}"

# 1. Генерация API Server сертификата
log_info "Генерация API Server сертификата"
generate_private_key "$APISERVER_DIR/apiserver.key" "$KEY_SIZE"

CONFIG_FILE="$APISERVER_DIR/apiserver.conf"
create_openssl_config "$CONFIG_FILE" "kube-apiserver" "${SAN_LIST[@]}"

cat >> "$CONFIG_FILE" <<EOF

[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, digitalSignature, keyEncipherment, keyCertSign
EOF

generate_csr "$APISERVER_DIR/apiserver.key" "$APISERVER_DIR/apiserver.csr" \
    "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/CN=kube-apiserver" \
    "$CONFIG_FILE"

sign_certificate "$APISERVER_DIR/apiserver.csr" "$APISERVER_DIR/apiserver.crt" \
    "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$CERT_VALIDITY_DAYS" \
    "v3_req" "$CONFIG_FILE"

# 2. Генерация API Server Kubelet Client сертификата
log_info "Генерация API Server Kubelet Client сертификата"
generate_private_key "$APISERVER_DIR/apiserver-kubelet-client.key" "$KEY_SIZE"

generate_csr "$APISERVER_DIR/apiserver-kubelet-client.key" \
    "$APISERVER_DIR/apiserver-kubelet-client.csr" \
    "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=system:masters/CN=kube-apiserver-kubelet-client"

sign_certificate "$APISERVER_DIR/apiserver-kubelet-client.csr" \
    "$APISERVER_DIR/apiserver-kubelet-client.crt" \
    "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$CERT_VALIDITY_DAYS"

# 3. Генерация API Server etcd Client сертификата
log_info "Генерация API Server etcd Client сертификата"
generate_private_key "$APISERVER_DIR/apiserver-etcd-client.key" "$KEY_SIZE"

generate_csr "$APISERVER_DIR/apiserver-etcd-client.key" \
    "$APISERVER_DIR/apiserver-etcd-client.csr" \
    "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=system:masters/CN=kube-apiserver-etcd-client"

sign_certificate "$APISERVER_DIR/apiserver-etcd-client.csr" \
    "$APISERVER_DIR/apiserver-etcd-client.crt" \
    "$CA_DIR/etcd-ca.crt" "$CA_DIR/etcd-ca.key" "$CERT_VALIDITY_DAYS"

# Проверка сертификатов
log_info "Проверка сгенерированных сертификатов"
verify_certificate "$APISERVER_DIR/apiserver.crt"
verify_certificate "$APISERVER_DIR/apiserver-kubelet-client.crt"
verify_certificate "$APISERVER_DIR/apiserver-etcd-client.crt"

log_success "Сертификаты API Server успешно сгенерированы в $APISERVER_DIR"

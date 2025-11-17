#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/common.sh"
source "$PROJECT_DIR/config/cluster.conf"

CA_DIR="$PROJECT_DIR/certs/ca"
PROXY_DIR="$PROJECT_DIR/certs/proxy"

log_info "Генерация сертификатов Kube Proxy"

# Генерация Kube Proxy Client сертификата
log_info "Генерация Kube Proxy Client сертификата"
generate_private_key "$PROXY_DIR/kube-proxy.key" "$KEY_SIZE"

generate_csr "$PROXY_DIR/kube-proxy.key" "$PROXY_DIR/kube-proxy.csr" \
    "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=system:node-proxier/CN=system:kube-proxy"

sign_certificate "$PROXY_DIR/kube-proxy.csr" "$PROXY_DIR/kube-proxy.crt" \
    "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$CERT_VALIDITY_DAYS"

# Проверка сертификата
verify_certificate "$PROXY_DIR/kube-proxy.crt"

# Создание kubeconfig для Kube Proxy
log_info "Создание kubeconfig для Kube Proxy"
cat > "$PROXY_DIR/kube-proxy.conf" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: $(base64 < "$CA_DIR/ca.crt" | tr -d '\n')
    server: https://${MASTER_IP}:6443
  name: ${CLUSTER_NAME}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    user: system:kube-proxy
  name: system:kube-proxy@${CLUSTER_NAME}
current-context: system:kube-proxy@${CLUSTER_NAME}
users:
- name: system:kube-proxy
  user:
    client-certificate-data: $(base64 < "$PROXY_DIR/kube-proxy.crt" | tr -d '\n')
    client-key-data: $(base64 < "$PROXY_DIR/kube-proxy.key" | tr -d '\n')
EOF

log_success "Сертификаты Kube Proxy успешно сгенерированы в $PROXY_DIR"

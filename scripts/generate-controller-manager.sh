#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/common.sh"
source "$PROJECT_DIR/config/cluster.conf"

CA_DIR="$PROJECT_DIR/certs/ca"
CM_DIR="$PROJECT_DIR/certs/controller-manager"

log_info "Генерация сертификатов Controller Manager"

# Генерация Controller Manager Client сертификата
log_info "Генерация Controller Manager Client сертификата"
generate_private_key "$CM_DIR/controller-manager.key" "$KEY_SIZE"

generate_csr "$CM_DIR/controller-manager.key" "$CM_DIR/controller-manager.csr" \
    "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=system:kube-controller-manager/CN=system:kube-controller-manager"

sign_certificate "$CM_DIR/controller-manager.csr" "$CM_DIR/controller-manager.crt" \
    "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$CERT_VALIDITY_DAYS"

# Проверка сертификата
verify_certificate "$CM_DIR/controller-manager.crt"

# Создание kubeconfig для Controller Manager
log_info "Создание kubeconfig для Controller Manager"
cat > "$CM_DIR/controller-manager.conf" <<EOF
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
    user: system:kube-controller-manager
  name: system:kube-controller-manager@${CLUSTER_NAME}
current-context: system:kube-controller-manager@${CLUSTER_NAME}
users:
- name: system:kube-controller-manager
  user:
    client-certificate-data: $(base64 < "$CM_DIR/controller-manager.crt" | tr -d '\n')
    client-key-data: $(base64 < "$CM_DIR/controller-manager.key" | tr -d '\n')
EOF

log_success "Сертификаты Controller Manager успешно сгенерированы в $CM_DIR"

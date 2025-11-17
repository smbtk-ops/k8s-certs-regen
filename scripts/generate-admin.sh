#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/common.sh"
source "$PROJECT_DIR/config/cluster.conf"

CA_DIR="$PROJECT_DIR/certs/ca"
ADMIN_DIR="$PROJECT_DIR/certs/admin"

log_info "Генерация admin сертификатов"

# Генерация Admin Client сертификата
log_info "Генерация Admin Client сертификата"
generate_private_key "$ADMIN_DIR/admin.key" "$KEY_SIZE"

generate_csr "$ADMIN_DIR/admin.key" "$ADMIN_DIR/admin.csr" \
    "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=system:masters/CN=kubernetes-admin"

sign_certificate "$ADMIN_DIR/admin.csr" "$ADMIN_DIR/admin.crt" \
    "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$CERT_VALIDITY_DAYS"

# Проверка сертификата
verify_certificate "$ADMIN_DIR/admin.crt"

# Создание admin kubeconfig
log_info "Создание admin kubeconfig"
cat > "$ADMIN_DIR/admin.conf" <<EOF
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
    user: kubernetes-admin
  name: kubernetes-admin@${CLUSTER_NAME}
current-context: kubernetes-admin@${CLUSTER_NAME}
users:
- name: kubernetes-admin
  user:
    client-certificate-data: $(base64 < "$ADMIN_DIR/admin.crt" | tr -d '\n')
    client-key-data: $(base64 < "$ADMIN_DIR/admin.key" | tr -d '\n')
EOF

log_success "Admin сертификаты успешно сгенерированы в $ADMIN_DIR"

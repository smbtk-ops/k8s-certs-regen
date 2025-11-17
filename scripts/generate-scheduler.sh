#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/common.sh"
source "$PROJECT_DIR/config/cluster.conf"

CA_DIR="$PROJECT_DIR/certs/ca"
SCHEDULER_DIR="$PROJECT_DIR/certs/scheduler"

log_info "Генерация сертификатов Scheduler"

# Генерация Scheduler Client сертификата
log_info "Генерация Scheduler Client сертификата"
generate_private_key "$SCHEDULER_DIR/scheduler.key" "$KEY_SIZE"

generate_csr "$SCHEDULER_DIR/scheduler.key" "$SCHEDULER_DIR/scheduler.csr" \
    "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=system:kube-scheduler/CN=system:kube-scheduler"

sign_certificate "$SCHEDULER_DIR/scheduler.csr" "$SCHEDULER_DIR/scheduler.crt" \
    "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$CERT_VALIDITY_DAYS"

# Проверка сертификата
verify_certificate "$SCHEDULER_DIR/scheduler.crt"

# Создание kubeconfig для Scheduler
log_info "Создание kubeconfig для Scheduler"
cat > "$SCHEDULER_DIR/scheduler.conf" <<EOF
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
    user: system:kube-scheduler
  name: system:kube-scheduler@${CLUSTER_NAME}
current-context: system:kube-scheduler@${CLUSTER_NAME}
users:
- name: system:kube-scheduler
  user:
    client-certificate-data: $(base64 < "$SCHEDULER_DIR/scheduler.crt" | tr -d '\n')
    client-key-data: $(base64 < "$SCHEDULER_DIR/scheduler.key" | tr -d '\n')
EOF

log_success "Сертификаты Scheduler успешно сгенерированы в $SCHEDULER_DIR"

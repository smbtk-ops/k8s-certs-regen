#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/common.sh"
source "$PROJECT_DIR/config/cluster.conf"

CA_DIR="$PROJECT_DIR/certs/ca"
KUBELET_DIR="$PROJECT_DIR/certs/kubelet"

log_info "Генерация сертификатов Kubelet"

# Функция генерации сертификата для одной ноды
generate_kubelet_cert() {
    local hostname="$1"
    local ip="$2"
    local node_dir="$KUBELET_DIR/$hostname"

    mkdir -p "$node_dir"

    log_info "Генерация сертификата Kubelet для $hostname ($ip)"

    generate_private_key "$node_dir/kubelet.key" "$KEY_SIZE"

    local config_file="$node_dir/kubelet.conf"
    create_openssl_config "$config_file" "system:node:$hostname" "$hostname" "$ip"

    generate_csr "$node_dir/kubelet.key" "$node_dir/kubelet.csr" \
        "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=system:nodes/CN=system:node:$hostname" \
        "$config_file"

    sign_certificate "$node_dir/kubelet.csr" "$node_dir/kubelet.crt" \
        "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$CERT_VALIDITY_DAYS" \
        "v3_req" "$config_file"

    verify_certificate "$node_dir/kubelet.crt"

    # Создание kubeconfig для kubelet
    cat > "$node_dir/kubelet.kubeconfig" <<EOF
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
    user: system:node:$hostname
  name: system:node:$hostname@${CLUSTER_NAME}
current-context: system:node:$hostname@${CLUSTER_NAME}
users:
- name: system:node:$hostname
  user:
    client-certificate-data: $(base64 < "$node_dir/kubelet.crt" | tr -d '\n')
    client-key-data: $(base64 < "$node_dir/kubelet.key" | tr -d '\n')
EOF

    log_success "Сертификат Kubelet для $hostname сгенерирован в $node_dir"
}

# Генерация для всех master нод (если указаны)
if [[ -n "${MASTER_NODES:-}" ]]; then
    log_info "Генерация kubelet сертификатов для всех master нод"
    for node in $MASTER_NODES; do
        IFS=':' read -r hostname ip <<< "$node"
        generate_kubelet_cert "$hostname" "$ip"
    done
else
    # Fallback на одну master ноду
    generate_kubelet_cert "$MASTER_HOSTNAME" "$MASTER_IP"
fi

# Генерация для worker нод (если указаны)
if [[ -n "${WORKER_NODES:-}" ]]; then
    log_info "Генерация kubelet сертификатов для всех worker нод"
    for node in $WORKER_NODES; do
        IFS=':' read -r hostname ip <<< "$node"
        generate_kubelet_cert "$hostname" "$ip"
    done
fi

log_success "Все сертификаты Kubelet успешно сгенерированы в $KUBELET_DIR"

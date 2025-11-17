#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/common.sh"
source "$PROJECT_DIR/config/cluster.conf"

BACKUP_DIR="$PROJECT_DIR/backup/$(date +%Y%m%d_%H%M%S)"

log_info "Создание резервной копии существующих сертификатов"

# Создание директории для резервной копии
mkdir -p "$BACKUP_DIR"

# Проверка существования директории с сертификатами
if [[ ! -d "$K8S_PKI_DIR" ]]; then
    log_warning "Директория $K8S_PKI_DIR не найдена"
    exit 0
fi

# Копирование всех сертификатов и ключей
log_info "Копирование сертификатов из $K8S_PKI_DIR"
cp -r "$K8S_PKI_DIR" "$BACKUP_DIR/"

# Копирование kubeconfig файлов
log_info "Копирование kubeconfig файлов"
if [[ -f "/etc/kubernetes/admin.conf" ]]; then
    cp /etc/kubernetes/admin.conf "$BACKUP_DIR/"
fi
if [[ -f "/etc/kubernetes/controller-manager.conf" ]]; then
    cp /etc/kubernetes/controller-manager.conf "$BACKUP_DIR/"
fi
if [[ -f "/etc/kubernetes/scheduler.conf" ]]; then
    cp /etc/kubernetes/scheduler.conf "$BACKUP_DIR/"
fi
if [[ -f "/etc/kubernetes/kubelet.conf" ]]; then
    cp /etc/kubernetes/kubelet.conf "$BACKUP_DIR/"
fi

# Создание манифеста резервной копии
log_info "Создание манифеста резервной копии"
cat > "$BACKUP_DIR/backup-manifest.txt" <<EOF
Backup Date: $(date)
Kubernetes PKI Directory: $K8S_PKI_DIR
Host: $(hostname)
User: $(whoami)

Files backed up:
EOF

find "$BACKUP_DIR" -type f >> "$BACKUP_DIR/backup-manifest.txt"

log_success "Резервная копия создана в $BACKUP_DIR"
log_info "Количество файлов: $(find "$BACKUP_DIR" -type f | wc -l)"

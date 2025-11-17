#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config/cluster.conf"

source "$SCRIPT_DIR/common.sh"

log_info "Применение kubeconfig файлов на все master ноды"

# Загрузка конфигурации
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Конфигурационный файл не найден: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

# Валидация VIP конфигурации
validate_vip_config

# Определение API Server endpoint для admin kubeconfig
if [[ "$USE_VIP" == "true" ]]; then
    API_SERVER_ENDPOINT="$LB_VIP"
    log_info "Admin kubeconfig будет использовать VIP: $API_SERVER_ENDPOINT"
else
    API_SERVER_ENDPOINT="$MASTER_IP"
    log_info "Admin kubeconfig будет использовать MASTER_IP: $API_SERVER_ENDPOINT"
fi

# Применение kubeconfig на всех master нодах
for node in $MASTER_NODES; do
    IFS=':' read -r hostname ip <<< "$node"

    log_info "Применение kubeconfig файлов на $hostname ($ip)..."

    # Копирование kubeconfig файлов на ноду
    log_info "Копирование kubeconfig файлов..."

    tmp_dir="/tmp/kubeconfigs-$hostname"
    mkdir -p "$tmp_dir"

    # Копируем готовые kubeconfig файлы
    cp "$PROJECT_DIR/certs/admin/admin.conf" "$tmp_dir/admin.conf"
    cp "$PROJECT_DIR/certs/admin/admin.conf" "$tmp_dir/super-admin.conf"
    cp "$PROJECT_DIR/certs/controller-manager/controller-manager.conf" "$tmp_dir/controller-manager.conf"
    cp "$PROJECT_DIR/certs/scheduler/scheduler.conf" "$tmp_dir/scheduler.conf"

    # Изменим server URL для admin и super-admin (VIP или MASTER_IP в зависимости от конфигурации)
    sed -i.bak "s|server: https://.*:6443|server: https://${API_SERVER_ENDPOINT}:6443|" "$tmp_dir/admin.conf"
    sed -i.bak "s|server: https://.*:6443|server: https://${API_SERVER_ENDPOINT}:6443|" "$tmp_dir/super-admin.conf"

    # Для остальных используем localhost
    sed -i.bak "s|server: https://.*:6443|server: https://127.0.0.1:6443|" "$tmp_dir/controller-manager.conf"
    sed -i.bak "s|server: https://.*:6443|server: https://127.0.0.1:6443|" "$tmp_dir/scheduler.conf"

    # Копирование на удаленную ноду
    scp -i "$SSH_KEY_PATH" -r "$tmp_dir" "$SSH_USER@$ip:/tmp/" || {
        log_error "Не удалось скопировать kubeconfig на $hostname"
        exit 1
    }

    # Применение на удаленной ноде
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$ip" bash -s << EOF
        # Backup существующих конфигов
        for conf in admin.conf super-admin.conf controller-manager.conf scheduler.conf; do
            if [ -f "/etc/kubernetes/\$conf" ]; then
                cp "/etc/kubernetes/\$conf" "/etc/kubernetes/\$conf.backup-\$(date +%Y%m%d-%H%M%S)"
            fi
        done

        # Применение новых kubeconfig
        cp /tmp/kubeconfigs-$hostname/admin.conf /etc/kubernetes/admin.conf
        cp /tmp/kubeconfigs-$hostname/super-admin.conf /etc/kubernetes/super-admin.conf
        cp /tmp/kubeconfigs-$hostname/controller-manager.conf /etc/kubernetes/controller-manager.conf
        cp /tmp/kubeconfigs-$hostname/scheduler.conf /etc/kubernetes/scheduler.conf

        # Установка правильных прав
        chmod 600 /etc/kubernetes/*.conf
        chown root:root /etc/kubernetes/*.conf

        echo "Kubeconfig файлы применены"
EOF

    if [ $? -eq 0 ]; then
        log_success "Kubeconfig файлы применены на $hostname"
    else
        log_error "Не удалось применить kubeconfig на $hostname"
        exit 1
    fi

    # Очистка временных файлов
    rm -rf "$tmp_dir"
done

log_success "Все kubeconfig файлы применены"
log_info "Теперь нужно перезапустить control plane компоненты"

#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config/cluster.conf"

source "$SCRIPT_DIR/common.sh"

log_info "Скрипт одновременного применения сертификатов на весь кластер"

# Загрузка конфигурации
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Конфигурационный файл не найден: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

log_warning "==================================="
log_warning "КРИТИЧЕСКИЕ ПРЕДУПРЕЖДЕНИЯ"
log_warning "==================================="
log_warning "1. Весь кластер будет ОСТАНОВЛЕН"
log_warning "2. Downtime составит 5-10 минут"
log_warning "3. Убедитесь что есть BACKUP"
log_warning "4. Рекомендуется запускать в maintenance window"
log_warning "==================================="
read -p "Вы уверены? Введите 'YES' для продолжения: " confirm

if [[ "$confirm" != "YES" ]]; then
    log_info "Операция отменена"
    exit 0
fi

# Подготовка сертификатов для всех нод
log_info "Подготовка сертификатов для всех master нод..."

for node in $MASTER_NODES; do
    IFS=':' read -r hostname ip <<< "$node"
    tmp_dir="/tmp/k8s-certs-$hostname"

    log_info "Подготовка для $hostname ($ip)"

    mkdir -p "$tmp_dir"/{k8s,etcd}

    # Kubernetes сертификаты
    cp "$PROJECT_DIR/certs/ca/ca.crt" "$tmp_dir/k8s/"
    cp "$PROJECT_DIR/certs/ca/ca.key" "$tmp_dir/k8s/"
    cp "$PROJECT_DIR/certs/apiserver/apiserver.crt" "$tmp_dir/k8s/"
    cp "$PROJECT_DIR/certs/apiserver/apiserver.key" "$tmp_dir/k8s/"
    cp "$PROJECT_DIR/certs/apiserver/apiserver-kubelet-client.crt" "$tmp_dir/k8s/"
    cp "$PROJECT_DIR/certs/apiserver/apiserver-kubelet-client.key" "$tmp_dir/k8s/"
    cp "$PROJECT_DIR/certs/ca/front-proxy-ca.crt" "$tmp_dir/k8s/"
    cp "$PROJECT_DIR/certs/ca/front-proxy-ca.key" "$tmp_dir/k8s/"
    cp "$PROJECT_DIR/certs/front-proxy/front-proxy-client.crt" "$tmp_dir/k8s/"
    cp "$PROJECT_DIR/certs/front-proxy/front-proxy-client.key" "$tmp_dir/k8s/"
    cp "$PROJECT_DIR/certs/sa/sa.key" "$tmp_dir/k8s/"
    cp "$PROJECT_DIR/certs/sa/sa.pub" "$tmp_dir/k8s/"
    cp "$PROJECT_DIR/certs/kubelet/$hostname/kubelet.crt" "$tmp_dir/k8s/"
    cp "$PROJECT_DIR/certs/kubelet/$hostname/kubelet.key" "$tmp_dir/k8s/"

    # etcd сертификаты
    cp "$PROJECT_DIR/certs/ca/etcd-ca.crt" "$tmp_dir/etcd/ca.pem"
    cp "$PROJECT_DIR/certs/ca/etcd-ca.key" "$tmp_dir/etcd/ca-key.pem"
    cp "$PROJECT_DIR/certs/etcd/$hostname/server.crt" "$tmp_dir/etcd/member-$hostname.pem"
    cp "$PROJECT_DIR/certs/etcd/$hostname/server.key" "$tmp_dir/etcd/member-$hostname-key.pem"
    cp "$PROJECT_DIR/certs/apiserver/apiserver-etcd-client.crt" "$tmp_dir/etcd/node-$hostname.pem"
    cp "$PROJECT_DIR/certs/apiserver/apiserver-etcd-client.key" "$tmp_dir/etcd/node-$hostname-key.pem"
    cp "$PROJECT_DIR/certs/etcd/shared/healthcheck-client.crt" "$tmp_dir/etcd/admin-$hostname.pem"
    cp "$PROJECT_DIR/certs/etcd/shared/healthcheck-client.key" "$tmp_dir/etcd/admin-$hostname-key.pem"

    # Копирование на ноду
    log_info "Копирование на $hostname..."
    scp -i "$SSH_KEY_PATH" -r "$tmp_dir" "$SSH_USER@$ip:/tmp/" || {
        log_error "Не удалось скопировать на $hostname"
        exit 1
    }
done

log_success "Сертификаты подготовлены и скопированы на все ноды"

# Создание backup на всех нодах
log_info "Создание backup на всех master нодах..."

for node in $MASTER_NODES; do
    IFS=':' read -r hostname ip <<< "$node"

    log_info "Backup на $hostname..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$ip" "
        BACKUP_DIR=/root/k8s-certs-backup-\$(date +%Y%m%d-%H%M%S)
        mkdir -p \$BACKUP_DIR
        cp -r /etc/kubernetes/ssl \$BACKUP_DIR/kubernetes-ssl
        cp -r /etc/ssl/etcd \$BACKUP_DIR/etcd
        cp /etc/kubernetes/*.conf \$BACKUP_DIR/
        cp /etc/etcd.env \$BACKUP_DIR/ 2>/dev/null || true
        cp -r /var/lib/kubelet/pki \$BACKUP_DIR/kubelet-pki 2>/dev/null || true
        echo \$BACKUP_DIR > /tmp/last-backup-dir
        echo \"Backup: \$BACKUP_DIR\"
    " || {
        log_error "Не удалось создать backup на $hostname"
        exit 1
    }
done

log_success "Backup создан на всех нодах"

# Остановка всего кластера
log_warning "==================================="
log_warning "ОСТАНОВКА КЛАСТЕРА"
log_warning "==================================="

log_info "Остановка kubelet на всех master нодах..."
for node in $MASTER_NODES; do
    IFS=':' read -r hostname ip <<< "$node"
    log_info "Остановка kubelet на $hostname..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$ip" "systemctl stop kubelet" &
done
wait

log_info "Остановка etcd на всех master нодах..."
for node in $MASTER_NODES; do
    IFS=':' read -r hostname ip <<< "$node"
    log_info "Остановка etcd на $hostname..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$ip" "systemctl stop etcd" &
done
wait

log_success "Кластер полностью остановлен"

# Применение сертификатов на всех нодах
log_info "Применение новых сертификатов на всех master нодах..."

for node in $MASTER_NODES; do
    IFS=':' read -r hostname ip <<< "$node"

    log_info "Применение на $hostname..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$ip" "
        # Kubernetes сертификаты - копируем явно по именам
        cd /tmp/k8s-certs-$hostname/k8s
        cp -f ca.crt /etc/kubernetes/ssl/
        cp -f ca.key /etc/kubernetes/ssl/
        cp -f apiserver.crt /etc/kubernetes/ssl/
        cp -f apiserver.key /etc/kubernetes/ssl/
        cp -f apiserver-kubelet-client.crt /etc/kubernetes/ssl/
        cp -f apiserver-kubelet-client.key /etc/kubernetes/ssl/
        cp -f front-proxy-ca.crt /etc/kubernetes/ssl/
        cp -f front-proxy-ca.key /etc/kubernetes/ssl/
        cp -f front-proxy-client.crt /etc/kubernetes/ssl/
        cp -f front-proxy-client.key /etc/kubernetes/ssl/
        cp -f sa.key /etc/kubernetes/ssl/
        cp -f sa.pub /etc/kubernetes/ssl/
        chmod 644 /etc/kubernetes/ssl/*.crt
        chmod 600 /etc/kubernetes/ssl/*.key
        chmod 600 /etc/kubernetes/ssl/sa.*

        # Kubelet сертификаты
        mkdir -p /var/lib/kubelet/pki
        cp -f kubelet.crt /var/lib/kubelet/pki/kubelet.crt
        cp -f kubelet.key /var/lib/kubelet/pki/kubelet.key
        chmod 644 /var/lib/kubelet/pki/kubelet.crt
        chmod 600 /var/lib/kubelet/pki/kubelet.key

        # etcd сертификаты - копируем явно по именам
        cd /tmp/k8s-certs-$hostname/etcd
        # Удаляем старые node-master*.pem и member-master*.pem файлы чтобы не было конфликтов
        rm -f /etc/ssl/etcd/ssl/node-master*.pem
        rm -f /etc/ssl/etcd/ssl/member-master*.pem
        rm -f /etc/ssl/etcd/ssl/admin-master*.pem
        cp -f ca.pem /etc/ssl/etcd/ssl/ca.pem
        cp -f ca-key.pem /etc/ssl/etcd/ssl/ca-key.pem
        cp -f member-$hostname.pem /etc/ssl/etcd/ssl/member-$hostname.pem
        cp -f member-$hostname-key.pem /etc/ssl/etcd/ssl/member-$hostname-key.pem
        cp -f node-$hostname.pem /etc/ssl/etcd/ssl/node-$hostname.pem
        cp -f node-$hostname-key.pem /etc/ssl/etcd/ssl/node-$hostname-key.pem
        cp -f admin-$hostname.pem /etc/ssl/etcd/ssl/admin-$hostname.pem
        cp -f admin-$hostname-key.pem /etc/ssl/etcd/ssl/admin-$hostname-key.pem
        chmod 700 /etc/ssl/etcd/ssl/*.pem
        chown -R etcd:root /etc/ssl/etcd/ssl/

        # Обновление манифеста API server для использования правильных имен сертификатов
        sed -i \"s|/etc/ssl/etcd/ssl/node-master1.pem|/etc/ssl/etcd/ssl/node-$hostname.pem|g\" /etc/kubernetes/manifests/kube-apiserver.yaml
        sed -i \"s|/etc/ssl/etcd/ssl/node-master1-key.pem|/etc/ssl/etcd/ssl/node-$hostname-key.pem|g\" /etc/kubernetes/manifests/kube-apiserver.yaml

        # Проверка правильности скопированных сертификатов
        echo \"Проверка правильности сертификатов на $hostname...\"

        # Проверка соответствия приватного ключа и сертификата API server
        API_CERT_MOD=\$(openssl x509 -noout -modulus -in /etc/kubernetes/ssl/apiserver.crt 2>/dev/null | openssl md5)
        API_KEY_MOD=\$(openssl rsa -noout -modulus -in /etc/kubernetes/ssl/apiserver.key 2>/dev/null | openssl md5)
        if [ \"\$API_CERT_MOD\" != \"\$API_KEY_MOD\" ]; then
            echo \"ОШИБКА: API server cert/key не соответствуют!\"
            exit 1
        fi
        echo \"✓ API server: cert и key соответствуют\"

        # Проверка соответствия приватного ключа и сертификата etcd client
        ETCD_CERT_MOD=\$(openssl x509 -noout -modulus -in /etc/ssl/etcd/ssl/node-$hostname.pem 2>/dev/null | openssl md5)
        ETCD_KEY_MOD=\$(openssl rsa -noout -modulus -in /etc/ssl/etcd/ssl/node-$hostname-key.pem 2>/dev/null | openssl md5)
        if [ \"\$ETCD_CERT_MOD\" != \"\$ETCD_KEY_MOD\" ]; then
            echo \"ОШИБКА: etcd client cert/key не соответствуют!\"
            exit 1
        fi
        echo \"✓ etcd client: cert и key соответствуют\"

        # Проверка что сертификаты подписаны правильным CA
        if ! openssl verify -CAfile /etc/kubernetes/ssl/ca.crt /etc/kubernetes/ssl/apiserver.crt >/dev/null 2>&1; then
            echo \"ОШИБКА: API server cert не подписан правильным CA!\"
            exit 1
        fi
        echo \"✓ API server: подписан правильным CA\"

        if ! openssl verify -CAfile /etc/ssl/etcd/ssl/ca.pem /etc/ssl/etcd/ssl/node-$hostname.pem >/dev/null 2>&1; then
            echo \"ОШИБКА: etcd client cert не подписан правильным CA!\"
            exit 1
        fi
        echo \"✓ etcd client: подписан правильным CA\"

        echo \"Все проверки сертификатов пройдены на $hostname\"
        echo \"Сертификаты применены на $hostname\"
    " || {
        log_error "Не удалось применить сертификаты на $hostname"
        log_error "Запускаем откат..."
        rollback_all
        exit 1
    }
done

log_success "Сертификаты применены на всех нодах"

# Запуск etcd на всех нодах одновременно
log_info "Запуск etcd на всех master нодах одновременно..."

for node in $MASTER_NODES; do
    IFS=':' read -r hostname ip <<< "$node"
    log_info "Запуск etcd на $hostname..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$ip" "systemctl start etcd" &
done
wait

# Пауза для старта etcd
sleep 10

# Проверка etcd
log_info "Проверка etcd кластера..."

FIRST_MASTER_IP=$(echo "$MASTER_NODES" | awk '{print $1}' | cut -d':' -f2)
FIRST_MASTER_HOST=$(echo "$MASTER_NODES" | awk '{print $1}' | cut -d':' -f1)

ssh -i "$SSH_KEY_PATH" "$SSH_USER@$FIRST_MASTER_IP" "
    ETCDCTL_API=3 etcdctl \
      --endpoints=https://192.168.88.191:2379,https://192.168.88.192:2379,https://192.168.88.193:2379 \
      --cacert=/etc/ssl/etcd/ssl/ca.pem \
      --cert=/etc/ssl/etcd/ssl/admin-$FIRST_MASTER_HOST.pem \
      --key=/etc/ssl/etcd/ssl/admin-$FIRST_MASTER_HOST-key.pem \
      endpoint health
" || {
    log_error "etcd health check failed!"
    log_error "Запускаем откат..."
    rollback_all
    exit 1
}

log_success "etcd кластер здоров!"

# Запуск kubelet на всех нодах
log_info "Запуск kubelet на всех master нодах..."

for node in $MASTER_NODES; do
    IFS=':' read -r hostname ip <<< "$node"
    log_info "Запуск kubelet на $hostname..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$ip" "systemctl start kubelet" &
done
wait

log_info "Ожидание старта control plane компонентов (30 секунд)..."
sleep 30

# Перезапуск etcd для гарантии загрузки нового CA
log_info "Перезапуск etcd для загрузки нового CA..."
for node in $MASTER_NODES; do
    IFS=':' read -r hostname ip <<< "$node"
    log_info "Перезапуск etcd на $hostname..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$ip" "systemctl restart etcd" &
done
wait

sleep 10

# Обновление kubeconfig файлов с новым CA
log_info "Обновление kubeconfig файлов на всех master нодах..."
"$SCRIPT_DIR/apply-kubeconfigs.sh" || {
    log_error "Не удалось обновить kubeconfig файлы"
    rollback_all
    exit 1
}

# Перезапуск control plane pods для применения новых kubeconfig
log_info "Перезапуск control plane компонентов..."
for node in $MASTER_NODES; do
    IFS=':' read -r hostname ip <<< "$node"
    log_info "Перезапуск pods на $hostname..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$ip" "
        crictl rm -f \$(crictl ps -a | grep kube-controller-manager | awk '{print \$1}') 2>/dev/null || true
        crictl rm -f \$(crictl ps -a | grep kube-scheduler | awk '{print \$1}') 2>/dev/null || true
        crictl rm -f \$(crictl ps -a | grep kube-apiserver | awk '{print \$1}') 2>/dev/null || true
        crictl rm -f \$(crictl ps | grep kube-vip | awk '{print \$1}') 2>/dev/null || true
    " &
done
wait

log_info "Ожидание перезапуска API servers (30 секунд)..."
sleep 30

# Копирование kubelet сертификатов на worker ноды
log_info "Копирование kubelet сертификатов на worker ноды..."
for node in $WORKER_NODES; do
    IFS=':' read -r hostname ip <<< "$node"
    log_info "Копирование kubelet сертификатов на $hostname..."

    scp -i "$SSH_KEY_PATH" \
        "$PROJECT_DIR/certs/kubelet/$hostname/kubelet.crt" \
        "$PROJECT_DIR/certs/kubelet/$hostname/kubelet.key" \
        "$SSH_USER@$ip:/tmp/" || {
        log_error "Не удалось скопировать kubelet сертификаты на $hostname"
        exit 1
    }

    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$ip" "
        mv /tmp/kubelet.crt /var/lib/kubelet/pki/kubelet.crt
        mv /tmp/kubelet.key /var/lib/kubelet/pki/kubelet.key
        chmod 644 /var/lib/kubelet/pki/kubelet.crt
        chmod 600 /var/lib/kubelet/pki/kubelet.key
    "
done

# Обновление kubelet.conf на всех нодах (master + worker)
log_info "Обновление kubelet.conf на всех нодах..."
CA_BASE64=$(base64 -i "$PROJECT_DIR/certs/ca/ca.crt" | tr -d '\n')

ALL_NODES="$MASTER_NODES $WORKER_NODES"
for node in $ALL_NODES; do
    IFS=':' read -r hostname ip <<< "$node"
    log_info "Обновление kubelet.conf на $hostname..."

    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$ip" bash -s << EOF
        # Обновляем certificate-authority-data в kubelet.conf
        sed -i.bak "s|certificate-authority-data:.*|certificate-authority-data: $CA_BASE64|" /etc/kubernetes/kubelet.conf

        # Пересоздаем kubelet-client-current.pem
        cat /var/lib/kubelet/pki/kubelet.crt /var/lib/kubelet/pki/kubelet.key > /var/lib/kubelet/pki/kubelet-client-current.pem
        chmod 600 /var/lib/kubelet/pki/kubelet-client-current.pem

        # Перезапускаем kubelet
        systemctl restart kubelet
EOF
done

log_info "Ожидание регистрации нод (30 секунд)..."
sleep 30

# Перезапуск Calico pods для обновления CA
log_info "Перезапуск Calico pods для применения нового CA..."
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$FIRST_MASTER_IP" "
    kubectl --kubeconfig=/etc/kubernetes/admin.conf delete pod -n kube-system -l k8s-app=calico-node --grace-period=0
" || log_warning "Не удалось перезапустить Calico pods"

log_info "Ожидание перезапуска Calico (60 секунд)..."
sleep 60

# Проверка кластера
log_info "Проверка кластера..."

ssh -i "$SSH_KEY_PATH" "$SSH_USER@$FIRST_MASTER_IP" "kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes" || {
    log_warning "kubectl не работает, возможно нужно больше времени..."
    sleep 30
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$FIRST_MASTER_IP" "kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes"
}

log_success "========================================="
log_success "КЛАСТЕР УСПЕШНО ОБНОВЛЕН!"
log_success "========================================="

log_info "Проверьте состояние кластера:"
log_info "  kubectl get nodes"
log_info "  kubectl get pods -A"

# Функция отката
rollback_all() {
    log_warning "========================================="
    log_warning "ОТКАТ ИЗМЕНЕНИЙ НА ВСЕХ НОДАХ"
    log_warning "========================================="

    for node in $MASTER_NODES; do
        IFS=':' read -r hostname ip <<< "$node"

        log_info "Откат на $hostname..."
        ssh -i "$SSH_KEY_PATH" "$SSH_USER@$ip" "
            BACKUP_DIR=\$(cat /tmp/last-backup-dir)
            systemctl stop kubelet || true
            systemctl stop etcd || true

            rm -rf /etc/kubernetes/ssl
            cp -r \$BACKUP_DIR/kubernetes-ssl /etc/kubernetes/ssl

            rm -rf /etc/ssl/etcd
            cp -r \$BACKUP_DIR/etcd /etc/ssl/

            if [ -d \$BACKUP_DIR/kubelet-pki ]; then
                rm -rf /var/lib/kubelet/pki
                cp -r \$BACKUP_DIR/kubelet-pki /var/lib/kubelet/pki
            fi

            echo \"Откат выполнен на $hostname\"
        " &
    done
    wait

    log_info "Запуск etcd на всех нодах..."
    for node in $MASTER_NODES; do
        IFS=':' read -r hostname ip <<< "$node"
        ssh -i "$SSH_KEY_PATH" "$SSH_USER@$ip" "systemctl start etcd" &
    done
    wait

    sleep 5

    log_info "Запуск kubelet на всех нодах..."
    for node in $MASTER_NODES; do
        IFS=':' read -r hostname ip <<< "$node"
        ssh -i "$SSH_KEY_PATH" "$SSH_USER@$ip" "systemctl start kubelet" &
    done
    wait

    log_success "Откат завершен"
}

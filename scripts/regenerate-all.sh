#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config/cluster.conf"

source "$SCRIPT_DIR/common.sh"

log_info "Начало регенерации всех сертификатов Kubernetes"

# Проверка наличия конфигурационного файла
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Конфигурационный файл не найден: $CONFIG_FILE"
    log_error "Скопируйте config/cluster.conf.example в config/cluster.conf и настройте его"
    exit 1
fi

# Загрузка конфигурации
source "$CONFIG_FILE"

# Проверка необходимых переменных
check_required_vars

# Проверка наличия необходимых инструментов
check_requirements

# Подтверждение от пользователя
log_warning "ВНИМАНИЕ: Процесс регенерации сертификатов приведет к временной недоступности кластера!"
log_warning "Убедитесь, что у вас есть резервная копия текущих сертификатов."
read -p "Продолжить? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    log_info "Операция отменена пользователем"
    exit 0
fi

# Удаление старой папки certs для гарантии чистоты
if [[ -d "$PROJECT_DIR/certs" ]]; then
    log_info "Удаление старой папки certs для обеспечения чистой генерации"
    rm -rf "$PROJECT_DIR/certs"
fi

# Создание директорий для сертификатов
log_info "Создание директорий для сертификатов"
mkdir -p "$PROJECT_DIR/certs"/{ca,apiserver,etcd,kubelet,controller-manager,scheduler,proxy,admin,sa}

# Шаг 1: Генерация CA сертификатов
log_info "Шаг 1: Генерация CA сертификатов"
"$SCRIPT_DIR/generate-ca.sh"

# Шаг 2: Генерация сертификатов API Server
log_info "Шаг 2: Генерация сертификатов API Server"
"$SCRIPT_DIR/generate-apiserver.sh"

# Шаг 3: Генерация сертификатов etcd
log_info "Шаг 3: Генерация сертификатов etcd"
if [[ -n "${ETCD_NODES:-}" ]]; then
    log_info "Обнаружена multi-master конфигурация, используем generate-etcd-multi.sh"
    "$SCRIPT_DIR/generate-etcd-multi.sh"
else
    "$SCRIPT_DIR/generate-etcd.sh"
fi

# Шаг 4: Генерация сертификатов kubelet
log_info "Шаг 4: Генерация сертификатов kubelet"
"$SCRIPT_DIR/generate-kubelet.sh"

# Шаг 5: Генерация сертификатов controller-manager
log_info "Шаг 5: Генерация сертификатов controller-manager"
"$SCRIPT_DIR/generate-controller-manager.sh"

# Шаг 6: Генерация сертификатов scheduler
log_info "Шаг 6: Генерация сертификатов scheduler"
"$SCRIPT_DIR/generate-scheduler.sh"

# Шаг 7: Генерация сертификатов proxy
log_info "Шаг 7: Генерация сертификатов proxy"
"$SCRIPT_DIR/generate-proxy.sh"

# Шаг 8: Генерация сертификатов admin
log_info "Шаг 8: Генерация сертификатов admin"
"$SCRIPT_DIR/generate-admin.sh"

# Шаг 9: Генерация Service Account ключей
log_info "Шаг 9: Генерация Service Account ключей"
"$SCRIPT_DIR/generate-sa-keys.sh"

# Шаг 10: Генерация Front Proxy сертификатов
log_info "Шаг 10: Генерация Front Proxy сертификатов"
"$SCRIPT_DIR/generate-front-proxy.sh"

log_success "Все сертификаты успешно сгенерированы!"
log_info "Сертификаты находятся в: $PROJECT_DIR/certs"
log_info ""
log_info "Следующие шаги:"
log_info "1. Проверьте сгенерированные сертификаты: ./scripts/verify-certs.sh"
log_info "2. Примените сертификаты на кластер: ./scripts/apply-all-at-once.sh"

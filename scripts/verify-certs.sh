#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/common.sh"
source "$PROJECT_DIR/config/cluster.conf"

CERTS_DIR="$PROJECT_DIR/certs"

log_info "Проверка сгенерированных сертификатов"

errors=0

# Функция проверки сертификата
check_cert() {
    local cert_path="$1"
    local description="$2"

    if [[ ! -f "$cert_path" ]]; then
        log_error "Сертификат не найден: $description ($cert_path)"
        ((errors++))
        return 1
    fi

    if ! openssl x509 -in "$cert_path" -noout -text &>/dev/null; then
        log_error "Невалидный сертификат: $description ($cert_path)"
        ((errors++))
        return 1
    fi

    local expiry=$(openssl x509 -in "$cert_path" -noout -enddate | cut -d= -f2)
    log_success "$description - OK (истекает: $expiry)"
    return 0
}

# Функция проверки ключа
check_key() {
    local key_path="$1"
    local description="$2"

    if [[ ! -f "$key_path" ]]; then
        log_error "Ключ не найден: $description ($key_path)"
        ((errors++))
        return 1
    fi

    if ! openssl rsa -in "$key_path" -check -noout &>/dev/null; then
        log_error "Невалидный ключ: $description ($key_path)"
        ((errors++))
        return 1
    fi

    log_success "$description - OK"
    return 0
}

# Проверка CA сертификатов
log_info "Проверка CA сертификатов"
check_cert "$CERTS_DIR/ca/ca.crt" "Kubernetes CA"
check_key "$CERTS_DIR/ca/ca.key" "Kubernetes CA Key"
check_cert "$CERTS_DIR/ca/etcd-ca.crt" "etcd CA"
check_key "$CERTS_DIR/ca/etcd-ca.key" "etcd CA Key"
check_cert "$CERTS_DIR/ca/front-proxy-ca.crt" "Front Proxy CA"
check_key "$CERTS_DIR/ca/front-proxy-ca.key" "Front Proxy CA Key"

# Проверка API Server сертификатов
log_info "Проверка API Server сертификатов"
check_cert "$CERTS_DIR/apiserver/apiserver.crt" "API Server"
check_key "$CERTS_DIR/apiserver/apiserver.key" "API Server Key"
check_cert "$CERTS_DIR/apiserver/apiserver-kubelet-client.crt" "API Server Kubelet Client"
check_key "$CERTS_DIR/apiserver/apiserver-kubelet-client.key" "API Server Kubelet Client Key"
check_cert "$CERTS_DIR/apiserver/apiserver-etcd-client.crt" "API Server etcd Client"
check_key "$CERTS_DIR/apiserver/apiserver-etcd-client.key" "API Server etcd Client Key"

# Проверка etcd сертификатов
log_info "Проверка etcd сертификатов"
check_cert "$CERTS_DIR/etcd/server.crt" "etcd Server"
check_key "$CERTS_DIR/etcd/server.key" "etcd Server Key"
check_cert "$CERTS_DIR/etcd/peer.crt" "etcd Peer"
check_key "$CERTS_DIR/etcd/peer.key" "etcd Peer Key"
check_cert "$CERTS_DIR/etcd/healthcheck-client.crt" "etcd Healthcheck Client"
check_key "$CERTS_DIR/etcd/healthcheck-client.key" "etcd Healthcheck Client Key"

# Проверка Controller Manager сертификатов
log_info "Проверка Controller Manager сертификатов"
check_cert "$CERTS_DIR/controller-manager/controller-manager.crt" "Controller Manager"
check_key "$CERTS_DIR/controller-manager/controller-manager.key" "Controller Manager Key"

# Проверка Scheduler сертификатов
log_info "Проверка Scheduler сертификатов"
check_cert "$CERTS_DIR/scheduler/scheduler.crt" "Scheduler"
check_key "$CERTS_DIR/scheduler/scheduler.key" "Scheduler Key"

# Проверка Admin сертификатов
log_info "Проверка Admin сертификатов"
check_cert "$CERTS_DIR/admin/admin.crt" "Admin"
check_key "$CERTS_DIR/admin/admin.key" "Admin Key"

# Проверка Proxy сертификатов
log_info "Проверка Proxy сертификатов"
check_cert "$CERTS_DIR/proxy/kube-proxy.crt" "Kube Proxy"
check_key "$CERTS_DIR/proxy/kube-proxy.key" "Kube Proxy Key"

# Проверка Service Account ключей
log_info "Проверка Service Account ключей"
check_key "$CERTS_DIR/sa/sa.key" "Service Account Key"
if [[ -f "$CERTS_DIR/sa/sa.pub" ]]; then
    log_success "Service Account Public Key - OK"
else
    log_error "Service Account Public Key не найден"
    ((errors++))
fi

# Проверка Front Proxy сертификатов
log_info "Проверка Front Proxy сертификатов"
check_cert "$CERTS_DIR/front-proxy/front-proxy-client.crt" "Front Proxy Client"
check_key "$CERTS_DIR/front-proxy/front-proxy-client.key" "Front Proxy Client Key"

# Итоги
echo ""
if [[ $errors -eq 0 ]]; then
    log_success "Все сертификаты прошли проверку успешно"
    exit 0
else
    log_error "Обнаружено ошибок: $errors"
    exit 1
fi

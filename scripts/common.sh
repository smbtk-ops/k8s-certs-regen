#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции логирования
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Проверка наличия необходимых инструментов
check_requirements() {
    local missing=0

    for cmd in openssl kubectl; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Требуемая команда не найдена: $cmd"
            missing=1
        fi
    done

    if [[ $missing -eq 1 ]]; then
        log_error "Установите недостающие зависимости и повторите попытку"
        exit 1
    fi

    log_success "Все необходимые инструменты установлены"
}

# Проверка обязательных переменных конфигурации
check_required_vars() {
    local vars=(
        "CLUSTER_NAME"
        "KUBERNETES_VERSION"
        "MASTER_IP"
        "CERT_VALIDITY_DAYS"
        "COUNTRY"
        "STATE"
        "LOCALITY"
        "ORGANIZATION"
        "USE_VIP"
        "ETCD_TYPE"
    )

    local missing=0
    for var in "${vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Переменная $var не установлена в конфигурации"
            missing=1
        fi
    done

    if [[ $missing -eq 1 ]]; then
        exit 1
    fi

    # Проверка допустимости значения ETCD_TYPE
    ETCD_TYPE_LOWER=$(echo "$ETCD_TYPE" | tr '[:upper:]' '[:lower:]')
    case "$ETCD_TYPE_LOWER" in
        auto|systemd|static-pod)
            # Нормализация значения
            ETCD_TYPE="$ETCD_TYPE_LOWER"
            ;;
        *)
            log_error "ETCD_TYPE должен быть 'auto', 'systemd' или 'static-pod', получено: '$ETCD_TYPE'"
            exit 1
            ;;
    esac
}

# Валидация конфигурации VIP
validate_vip_config() {
    local use_vip="${USE_VIP:-false}"

    # Нормализация значения USE_VIP (поддержка true/false, yes/no, 1/0)
    use_vip_lower=$(echo "$use_vip" | tr '[:upper:]' '[:lower:]')
    case "$use_vip_lower" in
        true|yes|1)
            USE_VIP="true"
            ;;
        false|no|0)
            USE_VIP="false"
            ;;
        *)
            log_error "USE_VIP должен быть 'true' или 'false', получено: '$use_vip'"
            exit 1
            ;;
    esac

    # Проверка если USE_VIP=true
    if [[ "$USE_VIP" == "true" ]]; then
        if [[ -z "${LB_VIP:-}" ]]; then
            log_error "USE_VIP=true, но LB_VIP не указан"
            log_error "Укажите LB_VIP в config/cluster.conf или установите USE_VIP=false"
            exit 1
        fi
        log_info "Режим HA с VIP: $LB_VIP"
    else
        if [[ -n "${LB_VIP:-}" ]]; then
            log_warning "USE_VIP=false, но LB_VIP указан ($LB_VIP)"
            log_warning "LB_VIP будет проигнорирован, используется MASTER_IP: $MASTER_IP"
        fi
        log_info "Режим без VIP: используется MASTER_IP: $MASTER_IP"
    fi
}

# Генерация приватного ключа
generate_private_key() {
    local key_file="$1"
    local key_size="${2:-2048}"

    log_info "Генерация приватного ключа: $key_file"
    openssl genrsa -out "$key_file" "$key_size" 2>/dev/null
}

# Генерация CSR
generate_csr() {
    local key_file="$1"
    local csr_file="$2"
    local subject="$3"
    local config_file="${4:-}"

    log_info "Генерация CSR: $csr_file"

    if [[ -n "$config_file" ]]; then
        openssl req -new -key "$key_file" -out "$csr_file" \
            -subj "$subject" -config "$config_file"
    else
        openssl req -new -key "$key_file" -out "$csr_file" -subj "$subject"
    fi
}

# Подпись сертификата
sign_certificate() {
    local csr_file="$1"
    local cert_file="$2"
    local ca_cert="$3"
    local ca_key="$4"
    local days="$5"
    local extensions="${6:-}"
    local config_file="${7:-}"

    log_info "Подпись сертификата: $cert_file"

    local cmd="openssl x509 -req -in \"$csr_file\" -CA \"$ca_cert\" -CAkey \"$ca_key\" \
        -CAcreateserial -out \"$cert_file\" -days \"$days\""

    if [[ -n "$extensions" && -n "$config_file" ]]; then
        cmd="$cmd -extensions \"$extensions\" -extfile \"$config_file\""
    fi

    eval "$cmd" 2>/dev/null
}

# Создание самоподписанного CA сертификата
create_ca_certificate() {
    local key_file="$1"
    local cert_file="$2"
    local subject="$3"
    local days="$4"

    log_info "Создание CA сертификата: $cert_file"

    openssl req -x509 -new -nodes -key "$key_file" -days "$days" \
        -out "$cert_file" -subj "$subject"
}

# Проверка сертификата
verify_certificate() {
    local cert_file="$1"

    if openssl x509 -in "$cert_file" -noout -text &>/dev/null; then
        log_success "Сертификат валиден: $cert_file"
        return 0
    else
        log_error "Сертификат невалиден: $cert_file"
        return 1
    fi
}

# Вывод информации о сертификате
show_certificate_info() {
    local cert_file="$1"

    echo "Информация о сертификате: $cert_file"
    openssl x509 -in "$cert_file" -noout -subject -issuer -dates
}

# Создание конфигурационного файла OpenSSL
create_openssl_config() {
    local config_file="$1"
    local cn="$2"
    shift 2
    local san_list=("$@")

    cat > "$config_file" <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name

[req_distinguished_name]

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
EOF

    if [[ ${#san_list[@]} -gt 0 ]]; then
        echo "subjectAltName = @alt_names" >> "$config_file"
        echo "" >> "$config_file"
        echo "[alt_names]" >> "$config_file"

        local idx=1
        for san in "${san_list[@]}"; do
            if [[ "$san" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "IP.$idx = $san" >> "$config_file"
            else
                echo "DNS.$idx = $san" >> "$config_file"
            fi
            ((idx++))
        done
    fi
}

# Создание резервной копии файла
backup_file() {
    local file="$1"
    local backup_dir="${2:-$PROJECT_DIR/backup}"

    if [[ -f "$file" ]]; then
        local filename=$(basename "$file")
        local timestamp=$(date +%Y%m%d_%H%M%S)
        local backup_file="$backup_dir/${filename}.${timestamp}.bak"

        mkdir -p "$backup_dir"
        cp "$file" "$backup_file"
        log_info "Создана резервная копия: $backup_file"
    fi
}

# Определение типа etcd на удаленной ноде
detect_etcd_type() {
    local node_ip="$1"
    local detected_type="unknown"

    log_info "Определение типа etcd на $node_ip..." >&2

    # Проверка systemd
    if ssh -i "$SSH_KEY_PATH" "$SSH_USER@$node_ip" "systemctl is-active etcd >/dev/null 2>&1"; then
        detected_type="systemd"
        log_info "Обнаружен etcd как systemd service" >&2
    # Проверка static pod
    elif ssh -i "$SSH_KEY_PATH" "$SSH_USER@$node_ip" "[ -f /etc/kubernetes/manifests/etcd.yaml ]"; then
        detected_type="static-pod"
        log_info "Обнаружен etcd как static pod" >&2
    else
        log_error "Не удалось определить тип etcd на $node_ip" >&2
        log_error "Проверьте что etcd запущен на этой ноде" >&2
        exit 1
    fi

    echo "$detected_type"
}

# Получение пути к сертификатам etcd в зависимости от типа
get_etcd_pki_path() {
    local etcd_type="$1"

    case "$etcd_type" in
        systemd)
            echo "/etc/ssl/etcd/ssl"
            ;;
        static-pod)
            echo "/etc/kubernetes/pki/etcd"
            ;;
        *)
            log_error "Неизвестный тип etcd: $etcd_type"
            exit 1
            ;;
    esac
}

# Остановка etcd на удаленной ноде
stop_etcd() {
    local node_ip="$1"
    local node_hostname="$2"
    local etcd_type="$3"

    log_info "Остановка etcd на $node_hostname ($node_ip) [тип: $etcd_type]..."

    case "$etcd_type" in
        systemd)
            ssh -i "$SSH_KEY_PATH" "$SSH_USER@$node_ip" "systemctl stop etcd" || {
                log_error "Не удалось остановить etcd через systemd на $node_hostname"
                return 1
            }
            ;;
        static-pod)
            ssh -i "$SSH_KEY_PATH" "$SSH_USER@$node_ip" "
                if [ -f '${ETCD_MANIFEST_PATH}' ]; then
                    mv '${ETCD_MANIFEST_PATH}' '/tmp/etcd.yaml.backup'
                    echo 'Static pod манифест перемещен в /tmp/etcd.yaml.backup'
                else
                    echo 'Манифест etcd не найден, возможно уже остановлен'
                fi
            " || {
                log_error "Не удалось остановить etcd static pod на $node_hostname"
                return 1
            }
            # Ждем пока pod остановится
            sleep 5
            ;;
        *)
            log_error "Неизвестный тип etcd: $etcd_type"
            return 1
            ;;
    esac

    log_success "etcd остановлен на $node_hostname"
}

# Запуск etcd на удаленной ноде
start_etcd() {
    local node_ip="$1"
    local node_hostname="$2"
    local etcd_type="$3"

    log_info "Запуск etcd на $node_hostname ($node_ip) [тип: $etcd_type]..."

    case "$etcd_type" in
        systemd)
            ssh -i "$SSH_KEY_PATH" "$SSH_USER@$node_ip" "systemctl start etcd" || {
                log_error "Не удалось запустить etcd через systemd на $node_hostname"
                return 1
            }
            ;;
        static-pod)
            ssh -i "$SSH_KEY_PATH" "$SSH_USER@$node_ip" "
                if [ -f '/tmp/etcd.yaml.backup' ]; then
                    mv '/tmp/etcd.yaml.backup' '${ETCD_MANIFEST_PATH}'
                    echo 'Static pod манифест восстановлен'
                else
                    echo 'ОШИБКА: backup манифеста не найден в /tmp/etcd.yaml.backup'
                    exit 1
                fi
            " || {
                log_error "Не удалось запустить etcd static pod на $node_hostname"
                return 1
            }
            # Ждем пока pod запустится
            sleep 10
            ;;
        *)
            log_error "Неизвестный тип etcd: $etcd_type"
            return 1
            ;;
    esac

    log_success "etcd запущен на $node_hostname"
}

# Определение и установка типа etcd для кластера
# Вызывать в начале скриптов после загрузки конфига
determine_etcd_type() {
    if [[ "$ETCD_TYPE" == "auto" ]]; then
        log_info "ETCD_TYPE=auto, определяем тип автоматически..."

        # Берем первую master ноду для определения
        local first_node=$(echo "$MASTER_NODES" | awk '{print $1}')
        IFS=':' read -r hostname ip <<< "$first_node"

        # Определяем тип на первой ноде
        ETCD_TYPE=$(detect_etcd_type "$ip")

        log_info "Определен тип etcd: $ETCD_TYPE"
        log_info "Все master ноды должны использовать тот же тип"
    else
        log_info "Используется заданный тип etcd: $ETCD_TYPE"
    fi

    # Экспортируем для использования в других частях скрипта
    export ETCD_TYPE
}

# Откат изменений на всех нодах
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

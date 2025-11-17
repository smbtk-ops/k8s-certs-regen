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

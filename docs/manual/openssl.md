# Ручная регенерация сертификатов Kubernetes через OpenSSL

Полное руководство по ручной регенерации всех сертификатов Kubernetes кластера с использованием стандартного инструмента OpenSSL.

## Содержание

1. [Введение](#введение)
2. [Подготовка](#подготовка)
3. [Полная замена сертификатов](#полная-замена-сертификатов)
4. [Модульное обновление](#модульное-обновление)
5. [Применение на кластер](#применение-на-кластер)
6. [Проверка и тестирование](#проверка-и-тестирование)
7. [Troubleshooting](#troubleshooting)
8. [Откат изменений](#откат-изменений)

## Введение

### Когда использовать OpenSSL метод

OpenSSL подходит если:
- Нужен полный контроль над всеми параметрами сертификатов
- Кластер установлен без kubeadm (Kubespray, Ansible, вручную)
- Требуются кастомные параметры (нестандартные SAN, CA constraints, extended key usage)
- Нет возможности установить дополнительные инструменты (CFSSL)
- Нужно глубокое понимание PKI процесса
- Специфичные требования безопасности

### Требования

**Инструменты:**
- OpenSSL 1.1.1+ (проверка: `openssl version`)
- SSH доступ ко всем нодам кластера
- Root права на всех нодах

**Знания:**
- Базовое понимание PKI и X.509 сертификатов
- Понимание архитектуры Kubernetes
- Базовые навыки работы с shell

**Время:**
- Подготовка и генерация сертификатов: 1-2 часа
- Применение на кластер: 15-30 минут
- Downtime кластера: 5-10 минут

### Что будет сгенерировано

Полный набор сертификатов для Kubernetes multi-master кластера:

**CA сертификаты (3):**
- Kubernetes CA
- etcd CA
- Front Proxy CA

**API Server сертификаты (3):**
- API Server server certificate
- API Server kubelet client certificate
- API Server etcd client certificate

**etcd сертификаты (3 типа × N нод):**
- etcd server certificates (hostname-specific)
- etcd peer certificates (hostname-specific)
- etcd healthcheck client certificate (shared)

**Kubelet сертификаты (N нод):**
- Kubelet client certificates для каждой ноды

**Control Plane компоненты (4):**
- Controller Manager client certificate
- Scheduler client certificate
- Kube Proxy client certificate
- Admin client certificate

**Дополнительные (2):**
- Service Account key pair
- Front Proxy client certificate

## Подготовка

### Шаг 1: Создание рабочей директории

```bash
# Создать директорию для работы
mkdir -p ~/k8s-certs-manual
cd ~/k8s-certs-manual

# Создать структуру поддиректорий
mkdir -p {ca,apiserver,etcd,kubelet,control-plane,sa,front-proxy,configs}
```

**Результат:**
```
k8s-certs-manual/
├── ca/              # CA сертификаты
├── apiserver/       # API Server сертификаты
├── etcd/            # etcd сертификаты
├── kubelet/         # Kubelet сертификаты
├── control-plane/   # Controller Manager, Scheduler, etc.
├── sa/              # Service Account ключи
├── front-proxy/     # Front Proxy сертификаты
└── configs/         # OpenSSL конфигурационные файлы
```

### Шаг 2: Backup существующих сертификатов

**КРИТИЧЕСКИ ВАЖНО:** Создайте backup перед любыми изменениями!

```bash
# На каждой master ноде
for node in master1:192.168.88.191 master2:192.168.88.192 master3:192.168.88.193; do
  IFS=':' read -r hostname ip <<< "$node"
  echo "=== Backup на $hostname ($ip) ==="

  ssh root@$ip "
    BACKUP_DIR=\"/root/k8s-certs-backup-\$(date +%Y%m%d)\"
    mkdir -p \$BACKUP_DIR

    # Backup Kubernetes сертификатов
    cp -r /etc/kubernetes/ssl \$BACKUP_DIR/kubernetes-ssl

    # Backup etcd сертификатов (путь зависит от типа)
    if [ -d /etc/ssl/etcd/ssl ]; then
      cp -r /etc/ssl/etcd \$BACKUP_DIR/etcd
    elif [ -d /etc/kubernetes/pki/etcd ]; then
      cp -r /etc/kubernetes/pki/etcd \$BACKUP_DIR/etcd
    fi

    # Backup kubeconfig файлов
    cp /etc/kubernetes/*.conf \$BACKUP_DIR/ 2>/dev/null || true

    # Backup kubelet
    cp -r /var/lib/kubelet/pki \$BACKUP_DIR/kubelet-pki 2>/dev/null || true

    echo \$BACKUP_DIR > /tmp/last-backup-dir
    echo \"Backup создан: \$BACKUP_DIR\"
  "
done
```

**Пример вывода:**
```
=== Backup на master1 (192.168.88.191) ===
Backup создан: /root/k8s-certs-backup-20250118_140530
=== Backup на master2 (192.168.88.192) ===
Backup создан: /root/k8s-certs-backup-20250118_140532
=== Backup на master3 (192.168.88.193) ===
Backup создан: /root/k8s-certs-backup-20250118_140534
```

### Шаг 3: Определение конфигурации кластера

Соберите информацию о вашем кластере:

```bash
# 1. Получить список master нод
kubectl get nodes -o wide | grep control-plane

# Пример вывода:
# master1   Ready   control-plane   192.168.88.191
# master2   Ready   control-plane   192.168.88.192
# master3   Ready   control-plane   192.168.88.193

# 2. Получить VIP (если используется)
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
# Пример: https://192.168.88.190:6443

# 3. Получить ClusterIP kubernetes service (ОБЯЗАТЕЛЬНО!)
kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}'
# Пример: 10.233.0.1

# 4. Определить тип etcd
"systemctl status etcd && echo 'Type: systemd'"
# ИЛИ
"ls /etc/kubernetes/manifests/etcd.yaml && echo 'Type: static-pod'"

# 5. Получить текущие SAN из сертификата
"openssl x509 -in /etc/kubernetes/ssl/apiserver.crt -noout -text | grep -A1 'Subject Alternative Name'"
```

### Шаг 4: Создание переменных конфигурации

Создайте файл с переменными конфигурации:

```bash
cat > ~/k8s-certs-manual/config.env <<'EOF'
# Базовая информация о кластере
CLUSTER_NAME="cluster.local"

# Master ноды (формат: hostname:ip)
MASTER_NODES=(
  "master1:192.168.88.191"
  "master2:192.168.88.192"
  "master3:192.168.88.193"
)

# Worker ноды
WORKER_NODES=(
  "worker1:192.168.88.194"
  "worker2:192.168.88.195"
)

# etcd ноды (обычно совпадает с master)
ETCD_NODES=(
  "master1:192.168.88.191"
  "master3:192.168.88.193"
  "master2:192.168.88.192"
)

# High Availability
USE_VIP="true"              # true или false
LB_VIP="192.168.88.190"     # Виртуальный IP (если USE_VIP=true)
LB_DNS=""                   # DNS для VIP (опционально)

# Сеть
SERVICE_CIDR="10.233.0.0/18"
POD_CIDR="10.233.64.0/18"
CLUSTER_DNS="10.96.0.10"

# API Server SAN (ВАЖНО: включить ВСЕ IP и DNS имена!)
API_SERVER_SANS=(
  "kubernetes"
  "kubernetes.default"
  "kubernetes.default.svc"
  "kubernetes.default.svc.cluster.local"
  "cluster.local"
  "192.168.88.190"        # LB_VIP
  "192.168.88.191"        # master1
  "192.168.88.192"        # master2
  "192.168.88.193"        # master3
  "127.0.0.1"
  "10.233.0.1"            # ClusterIP kubernetes service (ОБЯЗАТЕЛЬНО!)
)

# Тип etcd
ETCD_TYPE="systemd"         # systemd или static-pod

# Сертификаты
CERT_VALIDITY_DAYS=36500    # 100 лет
KEY_SIZE=2048               # или 4096

# Distinguished Name
COUNTRY="BY"
STATE="Minsk"
LOCALITY="Minsk"
ORGANIZATION="Kubernetes"
ORGANIZATIONAL_UNIT="cluster.local"

# Пути (зависят от типа etcd)
if [[ "$ETCD_TYPE" == "systemd" ]]; then
  ETCD_PKI_DIR="/etc/ssl/etcd/ssl"
  ETCD_CERT_EXT="pem"
else
  ETCD_PKI_DIR="/etc/kubernetes/pki/etcd"
  ETCD_CERT_EXT="crt"
fi

K8S_PKI_DIR="/etc/kubernetes/ssl"
EOF

# Загрузить переменные
source ~/k8s-certs-manual/config.env
```

**Объяснение параметров:**

- `CLUSTER_NAME` - имя кластера (обычно "cluster.local")
- `MASTER_NODES` - список всех master нод в формате hostname:ip
- `WORKER_NODES` - список worker нод
- `ETCD_NODES` - список etcd нод (порядок должен соответствовать ETCD_INITIAL_CLUSTER)
- `USE_VIP` - используется ли VIP для HA (true/false)
- `LB_VIP` - виртуальный IP load balancer'а (если USE_VIP=true)
- `API_SERVER_SANS` - **КРИТИЧЕСКИ ВАЖНО** - все IP и DNS имена для SAN
- `ETCD_TYPE` - тип развертывания etcd (systemd для Kubespray, static-pod для kubeadm)
- `CERT_VALIDITY_DAYS` - срок действия сертификатов (36500 = 100 лет)
- `KEY_SIZE` - размер RSA ключей (2048 или 4096)

**ВАЖНО:** Убедитесь что в `API_SERVER_SANS` включены:
- Все master IPs
- LB_VIP (если USE_VIP=true)
- ClusterIP kubernetes service (обязательно!)
- Стандартные DNS имена (kubernetes, kubernetes.default, etc.)

### Шаг 5: Проверка OpenSSL

```bash
# Проверить версию OpenSSL
openssl version

# Пример вывода:
# OpenSSL 1.1.1w  11 Sep 2023

# Проверить что версия >= 1.1.1
OPENSSL_VERSION=$(openssl version | awk '{print $2}')
if [[ "$OPENSSL_VERSION" < "1.1.1" ]]; then
  echo "ОШИБКА: Требуется OpenSSL 1.1.1 или новее"
  exit 1
fi
```

### Шаг 6: Создание вспомогательных функций

Создайте файл с функциями для упрощения работы:

```bash
cat > ~/k8s-certs-manual/functions.sh <<'EOF'
#!/bin/bash

# Генерация приватного ключа
generate_private_key() {
  local key_file="$1"
  local key_size="${2:-2048}"

  echo "[INFO] Генерация приватного ключа: $key_file"
  openssl genrsa -out "$key_file" "$key_size" 2>/dev/null
}

# Создание самоподписанного CA сертификата
create_ca_certificate() {
  local key_file="$1"
  local cert_file="$2"
  local subject="$3"
  local days="$4"

  echo "[INFO] Создание CA сертификата: $cert_file"
  openssl req -x509 -new -nodes -key "$key_file" -days "$days" \
    -out "$cert_file" -subj "$subject"
}

# Генерация CSR
generate_csr() {
  local key_file="$1"
  local csr_file="$2"
  local subject="$3"
  local config_file="${4:-}"

  echo "[INFO] Генерация CSR: $csr_file"
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

  echo "[INFO] Подпись сертификата: $cert_file"

  local cmd="openssl x509 -req -in \"$csr_file\" -CA \"$ca_cert\" -CAkey \"$ca_key\" \
    -CAcreateserial -out \"$cert_file\" -days \"$days\""

  if [[ -n "$extensions" && -n "$config_file" ]]; then
    cmd="$cmd -extensions \"$extensions\" -extfile \"$config_file\""
  fi

  eval "$cmd" 2>/dev/null
}

# Проверка сертификата
verify_certificate() {
  local cert_file="$1"

  if openssl x509 -in "$cert_file" -noout -text &>/dev/null; then
    echo "[SUCCESS] Сертификат валиден: $cert_file"
    return 0
  else
    echo "[ERROR] Сертификат невалиден: $cert_file"
    return 1
  fi
}

# Создание OpenSSL конфигурационного файла с SAN
create_openssl_config() {
  local config_file="$1"
  local cn="$2"
  shift 2
  local san_list=("$@")

  cat > "$config_file" <<EOL
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name

[req_distinguished_name]

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
EOL

  if [[ ${#san_list[@]} -gt 0 ]]; then
    echo "subjectAltName = @alt_names" >> "$config_file"
    echo "" >> "$config_file"
    echo "[alt_names]" >> "$config_file"

    local dns_idx=1
    local ip_idx=1
    for san in "${san_list[@]}"; do
      # Проверка является ли SAN IP адресом
      if [[ "$san" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "IP.$ip_idx = $san" >> "$config_file"
        ((ip_idx++))
      else
        echo "DNS.$dns_idx = $san" >> "$config_file"
        ((dns_idx++))
      fi
    done
  fi
}
EOF

chmod +x ~/k8s-certs-manual/functions.sh
source ~/k8s-certs-manual/functions.sh
```

## Полная замена сертификатов

Теперь переходим к генерации всех сертификатов.

### Блок 1: CA сертификаты

CA сертификаты - корень доверия для всех остальных сертификатов.

#### 1.1. Kubernetes CA

```bash
cd ~/k8s-certs-manual/ca

# Загрузить переменные и функции
source ../config.env
source ../functions.sh

# Генерация приватного ключа
generate_private_key "kubernetes-ca.key" "$KEY_SIZE"

# Создание самоподписанного CA сертификата
create_ca_certificate \
  "kubernetes-ca.key" \
  "kubernetes-ca.crt" \
  "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/OU=$ORGANIZATIONAL_UNIT/CN=kubernetes-ca" \
  "$CERT_VALIDITY_DAYS"

# Проверка
verify_certificate "kubernetes-ca.crt"
openssl x509 -in kubernetes-ca.crt -noout -text | head -20
```

**Пример вывода:**
```
[INFO] Генерация приватного ключа: kubernetes-ca.key
[INFO] Создание CA сертификата: kubernetes-ca.crt
[SUCCESS] Сертификат валиден: kubernetes-ca.crt
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number:
            xx:xx:xx:xx...
        Signature Algorithm: sha256WithRSAEncryption
        Issuer: C = BY, ST = Minsk, L = Minsk, O = Kubernetes, OU = cluster.local, CN = kubernetes-ca
        Validity
            Not Before: Jan 18 12:00:00 2025 GMT
            Not After : Jan 18 12:00:00 2125 GMT
        Subject: C = BY, ST = Minsk, L = Minsk, O = Kubernetes, OU = cluster.local, CN = kubernetes-ca
```

**Что делает:**
- Создает RSA приватный ключ размером KEY_SIZE бит
- Создает самоподписанный сертификат CA на 100 лет
- Subject DN включает информацию об организации и CN=kubernetes-ca

#### 1.2. etcd CA

```bash
# Генерация приватного ключа
generate_private_key "etcd-ca.key" "$KEY_SIZE"

# Создание самоподписанного CA сертификата
create_ca_certificate \
  "etcd-ca.key" \
  "etcd-ca.crt" \
  "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/OU=$ORGANIZATIONAL_UNIT/CN=etcd-ca" \
  "$CERT_VALIDITY_DAYS"

# Проверка
verify_certificate "etcd-ca.crt"
```

#### 1.3. Front Proxy CA

```bash
# Генерация приватного ключа
generate_private_key "front-proxy-ca.key" "$KEY_SIZE"

# Создание самоподписанного CA сертификата
create_ca_certificate \
  "front-proxy-ca.key" \
  "front-proxy-ca.crt" \
  "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/OU=$ORGANIZATIONAL_UNIT/CN=front-proxy-ca" \
  "$CERT_VALIDITY_DAYS"

# Проверка
verify_certificate "front-proxy-ca.crt"
```

**Результат:**
```bash
ls -lh ~/k8s-certs-manual/ca/

# Вывод:
# -rw------- 1 root root 1.7K Jan 18 12:00 kubernetes-ca.key
# -rw-r--r-- 1 root root 1.3K Jan 18 12:00 kubernetes-ca.crt
# -rw------- 1 root root 1.7K Jan 18 12:00 etcd-ca.key
# -rw-r--r-- 1 root root 1.3K Jan 18 12:00 etcd-ca.crt
# -rw------- 1 root root 1.7K Jan 18 12:00 front-proxy-ca.key
# -rw-r--r-- 1 root root 1.3K Jan 18 12:00 front-proxy-ca.crt
```

### Блок 2: API Server сертификаты

API Server требует три сертификата.

#### 2.1. API Server Server Certificate

**КРИТИЧЕСКИ ВАЖНО:** SAN должен включать **ВСЕ** IP и DNS имена.

```bash
cd ~/k8s-certs-manual/apiserver

# Загрузить переменные и функции
source ../config.env
source ../functions.sh

# Подготовка SAN списка
SAN_LIST=()

# Добавить VIP если используется
if [[ "$USE_VIP" == "true" && -n "$LB_VIP" ]]; then
  SAN_LIST+=("$LB_VIP")
  echo "[INFO] Добавлен LB_VIP в SAN: $LB_VIP"
fi

# Добавить LB_DNS если указан
if [[ -n "$LB_DNS" ]]; then
  SAN_LIST+=("$LB_DNS")
  echo "[INFO] Добавлен LB_DNS в SAN: $LB_DNS"
fi

# Добавить все значения из API_SERVER_SANS
for san in "${API_SERVER_SANS[@]}"; do
  SAN_LIST+=("$san")
done

# Вывести итоговый список SAN
echo "[INFO] Полный список SAN для API Server:"
for san in "${SAN_LIST[@]}"; do
  echo "  - $san"
done

# Создать OpenSSL конфиг с SAN
create_openssl_config \
  "../configs/apiserver.conf" \
  "kube-apiserver" \
  "${SAN_LIST[@]}"

# Генерация приватного ключа
generate_private_key "apiserver.key" "$KEY_SIZE"

# Генерация CSR
generate_csr \
  "apiserver.key" \
  "apiserver.csr" \
  "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/OU=$ORGANIZATIONAL_UNIT/CN=kube-apiserver" \
  "../configs/apiserver.conf"

# Подпись сертификата
sign_certificate \
  "apiserver.csr" \
  "apiserver.crt" \
  "../ca/kubernetes-ca.crt" \
  "../ca/kubernetes-ca.key" \
  "$CERT_VALIDITY_DAYS" \
  "v3_req" \
  "../configs/apiserver.conf"

# Проверка
verify_certificate "apiserver.crt"

# Проверить SAN в сертификате
echo "[INFO] Проверка SAN в сертификате:"
openssl x509 -in apiserver.crt -noout -text | grep -A2 "Subject Alternative Name"
```

**Пример вывода:**
```
[INFO] Добавлен LB_VIP в SAN: 192.168.88.190
[INFO] Полный список SAN для API Server:
  - 192.168.88.190
  - kubernetes
  - kubernetes.default
  - kubernetes.default.svc
  - kubernetes.default.svc.cluster.local
  - cluster.local
  - 192.168.88.191
  - 192.168.88.192
  - 192.168.88.193
  - 127.0.0.1
  - 10.233.0.1
[INFO] Генерация приватного ключа: apiserver.key
[INFO] Генерация CSR: apiserver.csr
[INFO] Подпись сертификата: apiserver.crt
[SUCCESS] Сертификат валиден: apiserver.crt
[INFO] Проверка SAN в сертификате:
            X509v3 Subject Alternative Name:
                DNS:kubernetes, DNS:kubernetes.default, DNS:kubernetes.default.svc, DNS:kubernetes.default.svc.cluster.local, DNS:cluster.local, IP Address:192.168.88.190, IP Address:192.168.88.191, IP Address:192.168.88.192, IP Address:192.168.88.193, IP Address:127.0.0.1, IP Address:10.233.0.1
```

**Объяснение:**
- CN=kube-apiserver - Common Name для API Server
- SAN включает ВСЕ возможные способы доступа к API Server
- Подписан Kubernetes CA
- Validity 100 лет

#### 2.2. API Server Kubelet Client Certificate

```bash
# Генерация приватного ключа
generate_private_key "apiserver-kubelet-client.key" "$KEY_SIZE"

# Генерация CSR
generate_csr \
  "apiserver-kubelet-client.key" \
  "apiserver-kubelet-client.csr" \
  "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=system:masters/CN=kube-apiserver-kubelet-client"

# Подпись сертификата
sign_certificate \
  "apiserver-kubelet-client.csr" \
  "apiserver-kubelet-client.crt" \
  "../ca/kubernetes-ca.crt" \
  "../ca/kubernetes-ca.key" \
  "$CERT_VALIDITY_DAYS"

# Проверка
verify_certificate "apiserver-kubelet-client.crt"
```

**Объяснение:**
- CN=kube-apiserver-kubelet-client
- O=system:masters - группа с полными правами
- Используется API Server для подключения к Kubelet

#### 2.3. API Server etcd Client Certificate

```bash
# Генерация приватного ключа
generate_private_key "apiserver-etcd-client.key" "$KEY_SIZE"

# Генерация CSR
generate_csr \
  "apiserver-etcd-client.key" \
  "apiserver-etcd-client.csr" \
  "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=system:masters/CN=kube-apiserver-etcd-client"

# Подпись сертификата (используем etcd CA!)
sign_certificate \
  "apiserver-etcd-client.csr" \
  "apiserver-etcd-client.crt" \
  "../ca/etcd-ca.crt" \
  "../ca/etcd-ca.key" \
  "$CERT_VALIDITY_DAYS"

# Проверка
verify_certificate "apiserver-etcd-client.crt"
```

**ВАЖНО:** Этот сертификат подписан **etcd CA**, а не Kubernetes CA!

**Результат:**
```bash
ls -lh ~/k8s-certs-manual/apiserver/

# Вывод:
# -rw------- 1 root root 1.7K Jan 18 12:10 apiserver.key
# -rw-r--r-- 1 root root 1.5K Jan 18 12:10 apiserver.crt
# -rw-r--r-- 1 root root 1.1K Jan 18 12:10 apiserver.csr
# -rw------- 1 root root 1.7K Jan 18 12:11 apiserver-kubelet-client.key
# -rw-r--r-- 1 root root 1.2K Jan 18 12:11 apiserver-kubelet-client.crt
# -rw------- 1 root root 1.7K Jan 18 12:12 apiserver-etcd-client.key
# -rw-r--r-- 1 root root 1.2K Jan 18 12:12 apiserver-etcd-client.crt
```

### Блок 3: etcd сертификаты

etcd требует **hostname-specific** сертификаты для каждой ноды.

**ВАЖНО:**
- Каждая нода получает уникальные сертификаты с hostname в имени
- SAN должен включать **ВСЕ** etcd ноды (для peer communication)

#### 3.1. Общий healthcheck client сертификат

```bash
cd ~/k8s-certs-manual/etcd
mkdir -p shared

# Загрузить переменные и функции
source ../config.env
source ../functions.sh

# Генерация приватного ключа
generate_private_key "shared/healthcheck-client.key" "$KEY_SIZE"

# Генерация CSR
generate_csr \
  "shared/healthcheck-client.key" \
  "shared/healthcheck-client.csr" \
  "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=system:masters/CN=kube-etcd-healthcheck-client"

# Подпись сертификата (используем etcd CA!)
sign_certificate \
  "shared/healthcheck-client.csr" \
  "shared/healthcheck-client.crt" \
  "../ca/etcd-ca.crt" \
  "../ca/etcd-ca.key" \
  "$CERT_VALIDITY_DAYS"

# Проверка
verify_certificate "shared/healthcheck-client.crt"
```

#### 3.2. Сертификаты для каждой etcd ноды

**Подготовка SAN списка для etcd:**

```bash
# Подготовить полный SAN список для всех etcd нод
ALL_ETCD_SANS=()
for node in "${ETCD_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"
  ALL_ETCD_SANS+=("$hostname" "$ip")
done
ALL_ETCD_SANS+=("127.0.0.1" "localhost")

echo "[INFO] SAN список для etcd сертификатов:"
for san in "${ALL_ETCD_SANS[@]}"; do
  echo "  - $san"
done
```

**Генерация для каждой ноды:**

```bash
for node in "${ETCD_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"

  echo "========================================="
  echo "Генерация сертификатов etcd для $hostname ($ip)"
  echo "========================================="

  # Создать директорию для ноды
  mkdir -p "$hostname"

  # --- 1. etcd Server сертификат ---
  echo "[INFO] Генерация etcd Server сертификата для $hostname"

  # Создать конфиг с SAN
  create_openssl_config \
    "../configs/etcd-server-$hostname.conf" \
    "$hostname" \
    "${ALL_ETCD_SANS[@]}"

  # Добавить extendedKeyUsage для server и client auth
  cat >> "../configs/etcd-server-$hostname.conf" <<'EOL'
extendedKeyUsage = serverAuth, clientAuth
EOL

  # Генерация ключа
  generate_private_key "$hostname/server.key" "$KEY_SIZE"

  # Генерация CSR
  generate_csr \
    "$hostname/server.key" \
    "$hostname/server.csr" \
    "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/CN=$hostname" \
    "../configs/etcd-server-$hostname.conf"

  # Подпись
  sign_certificate \
    "$hostname/server.csr" \
    "$hostname/server.crt" \
    "../ca/etcd-ca.crt" \
    "../ca/etcd-ca.key" \
    "$CERT_VALIDITY_DAYS" \
    "v3_req" \
    "../configs/etcd-server-$hostname.conf"

  verify_certificate "$hostname/server.crt"

  # --- 2. etcd Peer сертификат ---
  echo "[INFO] Генерация etcd Peer сертификата для $hostname"

  # Создать конфиг с SAN
  create_openssl_config \
    "../configs/etcd-peer-$hostname.conf" \
    "$hostname" \
    "${ALL_ETCD_SANS[@]}"

  # Добавить extendedKeyUsage
  cat >> "../configs/etcd-peer-$hostname.conf" <<'EOL'
extendedKeyUsage = serverAuth, clientAuth
EOL

  # Генерация ключа
  generate_private_key "$hostname/peer.key" "$KEY_SIZE"

  # Генерация CSR
  generate_csr \
    "$hostname/peer.key" \
    "$hostname/peer.csr" \
    "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/CN=$hostname" \
    "../configs/etcd-peer-$hostname.conf"

  # Подпись
  sign_certificate \
    "$hostname/peer.csr" \
    "$hostname/peer.crt" \
    "../ca/etcd-ca.crt" \
    "../ca/etcd-ca.key" \
    "$CERT_VALIDITY_DAYS" \
    "v3_req" \
    "../configs/etcd-peer-$hostname.conf"

  verify_certificate "$hostname/peer.crt"

  echo "[SUCCESS] Сертификаты etcd для $hostname сгенерированы"
done
```

**Пример вывода:**
```
=========================================
Генерация сертификатов etcd для master1 (192.168.88.191)
=========================================
[INFO] Генерация etcd Server сертификата для master1
[INFO] Генерация приватного ключа: master1/server.key
[INFO] Генерация CSR: master1/server.csr
[INFO] Подпись сертификата: master1/server.crt
[SUCCESS] Сертификат валиден: master1/server.crt
[INFO] Генерация etcd Peer сертификата для master1
[INFO] Генерация приватного ключа: master1/peer.key
[INFO] Генерация CSR: master1/peer.csr
[INFO] Подпись сертификата: master1/peer.crt
[SUCCESS] Сертификат валиден: master1/peer.crt
[SUCCESS] Сертификаты etcd для master1 сгенерированы
=========================================
Генерация сертификатов etcd для master2 (192.168.88.192)
...
```

**Результат:**
```bash
tree ~/k8s-certs-manual/etcd/

# etcd/
# ├── shared/
# │   ├── healthcheck-client.key
# │   └── healthcheck-client.crt
# ├── master1/
# │   ├── server.key
# │   ├── server.crt
# │   ├── peer.key
# │   └── peer.crt
# ├── master2/
# │   ├── server.key
# │   ├── server.crt
# │   ├── peer.key
# │   └── peer.crt
# └── master3/
#     ├── server.key
#     ├── server.crt
#     ├── peer.key
#     └── peer.crt
```

### Блок 4: Kubelet сертификаты

Каждая нода (master и worker) требует уникальный kubelet сертификат.

```bash
cd ~/k8s-certs-manual/kubelet

# Загрузить переменные и функции
source ../config.env
source ../functions.sh

# Объединить master и worker ноды
ALL_NODES=("${MASTER_NODES[@]}" "${WORKER_NODES[@]}")

for node in "${ALL_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"

  echo "[INFO] Генерация Kubelet сертификата для $hostname ($ip)"

  # Создать директорию
  mkdir -p "$hostname"

  # Создать конфиг с SAN
  create_openssl_config \
    "../configs/kubelet-$hostname.conf" \
    "system:node:$hostname" \
    "$hostname" "$ip"

  # Генерация ключа
  generate_private_key "$hostname/kubelet.key" "$KEY_SIZE"

  # Генерация CSR
  # ВАЖНО: CN=system:node:{hostname}, O=system:nodes
  generate_csr \
    "$hostname/kubelet.key" \
    "$hostname/kubelet.csr" \
    "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=system:nodes/CN=system:node:$hostname" \
    "../configs/kubelet-$hostname.conf"

  # Подпись
  sign_certificate \
    "$hostname/kubelet.csr" \
    "$hostname/kubelet.crt" \
    "../ca/kubernetes-ca.crt" \
    "../ca/kubernetes-ca.key" \
    "$CERT_VALIDITY_DAYS" \
    "v3_req" \
    "../configs/kubelet-$hostname.conf"

  verify_certificate "$hostname/kubelet.crt"
done
```

**Объяснение:**
- CN=system:node:{hostname} - специальный формат для Node Authorization
- O=system:nodes - группа для kubelet
- SAN включает hostname и IP ноды

**Результат:**
```bash
ls -lh ~/k8s-certs-manual/kubelet/

# master1/
#   kubelet.key
#   kubelet.crt
# master2/
#   kubelet.key
#   kubelet.crt
# master3/
#   kubelet.key
#   kubelet.crt
# worker1/
#   kubelet.key
#   kubelet.crt
# worker2/
#   kubelet.key
#   kubelet.crt
```

### Блок 5: Control Plane компоненты

Генерация сертификатов для компонентов control plane.

```bash
cd ~/k8s-certs-manual/control-plane

# Загрузить переменные и функции
source ../config.env
source ../functions.sh
```

#### 5.1. Controller Manager

```bash
# Генерация ключа
generate_private_key "controller-manager.key" "$KEY_SIZE"

# Генерация CSR
generate_csr \
  "controller-manager.key" \
  "controller-manager.csr" \
  "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=system:kube-controller-manager/CN=system:kube-controller-manager"

# Подпись
sign_certificate \
  "controller-manager.csr" \
  "controller-manager.crt" \
  "../ca/kubernetes-ca.crt" \
  "../ca/kubernetes-ca.key" \
  "$CERT_VALIDITY_DAYS"

verify_certificate "controller-manager.crt"
```

#### 5.2. Scheduler

```bash
# Генерация ключа
generate_private_key "scheduler.key" "$KEY_SIZE"

# Генерация CSR
generate_csr \
  "scheduler.key" \
  "scheduler.csr" \
  "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=system:kube-scheduler/CN=system:kube-scheduler"

# Подпись
sign_certificate \
  "scheduler.csr" \
  "scheduler.crt" \
  "../ca/kubernetes-ca.crt" \
  "../ca/kubernetes-ca.key" \
  "$CERT_VALIDITY_DAYS"

verify_certificate "scheduler.crt"
```

#### 5.3. Kube Proxy

```bash
# Генерация ключа
generate_private_key "kube-proxy.key" "$KEY_SIZE"

# Генерация CSR
generate_csr \
  "kube-proxy.key" \
  "kube-proxy.csr" \
  "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=system:node-proxier/CN=system:kube-proxy"

# Подпись
sign_certificate \
  "kube-proxy.csr" \
  "kube-proxy.crt" \
  "../ca/kubernetes-ca.crt" \
  "../ca/kubernetes-ca.key" \
  "$CERT_VALIDITY_DAYS"

verify_certificate "kube-proxy.crt"
```

#### 5.4. Admin

```bash
# Генерация ключа
generate_private_key "admin.key" "$KEY_SIZE"

# Генерация CSR
# ВАЖНО: O=system:masters даёт полные права
generate_csr \
  "admin.key" \
  "admin.csr" \
  "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=system:masters/CN=kubernetes-admin"

# Подпись
sign_certificate \
  "admin.csr" \
  "admin.crt" \
  "../ca/kubernetes-ca.crt" \
  "../ca/kubernetes-ca.key" \
  "$CERT_VALIDITY_DAYS"

verify_certificate "admin.crt"
```

### Блок 6: Service Account ключи

Service Account использует ключевую пару RSA для подписи токенов.

```bash
cd ~/k8s-certs-manual/sa

# Загрузить переменные
source ../config.env

# Генерация приватного ключа
echo "[INFO] Генерация Service Account приватного ключа"
openssl genrsa -out sa.key "$KEY_SIZE" 2>/dev/null

# Извлечение публичного ключа
echo "[INFO] Извлечение публичного ключа"
openssl rsa -in sa.key -pubout -out sa.pub 2>/dev/null

echo "[SUCCESS] Service Account ключи сгенерированы"

# Проверка
ls -lh
```

### Блок 7: Front Proxy

```bash
cd ~/k8s-certs-manual/front-proxy

# Загрузить переменные и функции
source ../config.env
source ../functions.sh

# Генерация ключа
generate_private_key "front-proxy-client.key" "$KEY_SIZE"

# Генерация CSR
generate_csr \
  "front-proxy-client.key" \
  "front-proxy-client.csr" \
  "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/CN=front-proxy-client"

# Подпись (используем front-proxy CA!)
sign_certificate \
  "front-proxy-client.csr" \
  "front-proxy-client.crt" \
  "../ca/front-proxy-ca.crt" \
  "../ca/front-proxy-ca.key" \
  "$CERT_VALIDITY_DAYS"

verify_certificate "front-proxy-client.crt"
```

### Итоговая проверка всех сертификатов

```bash
cd ~/k8s-certs-manual

echo "========================================="
echo "Проверка всех сгенерированных сертификатов"
echo "========================================="

# Функция проверки сертификата
check_cert() {
  local cert_file="$1"
  if [[ -f "$cert_file" ]]; then
    if openssl x509 -in "$cert_file" -noout -text &>/dev/null; then
      local subject=$(openssl x509 -in "$cert_file" -noout -subject | sed 's/subject=//')
      local dates=$(openssl x509 -in "$cert_file" -noout -dates)
      echo "[OK] $cert_file"
      echo "     Subject: $subject"
    else
      echo "[ERROR] $cert_file - невалидный сертификат"
    fi
  else
    echo "[MISSING] $cert_file - файл не найден"
  fi
}

# Проверка CA
echo "=== CA Сертификаты ==="
check_cert "ca/kubernetes-ca.crt"
check_cert "ca/etcd-ca.crt"
check_cert "ca/front-proxy-ca.crt"

# Проверка API Server
echo ""
echo "=== API Server Сертификаты ==="
check_cert "apiserver/apiserver.crt"
check_cert "apiserver/apiserver-kubelet-client.crt"
check_cert "apiserver/apiserver-etcd-client.crt"

# Проверка etcd
echo ""
echo "=== etcd Сертификаты ==="
check_cert "etcd/shared/healthcheck-client.crt"
for node in "${ETCD_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"
  check_cert "etcd/$hostname/server.crt"
  check_cert "etcd/$hostname/peer.crt"
done

# Проверка Kubelet
echo ""
echo "=== Kubelet Сертификаты ==="
ALL_NODES=("${MASTER_NODES[@]}" "${WORKER_NODES[@]}")
for node in "${ALL_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"
  check_cert "kubelet/$hostname/kubelet.crt"
done

# Проверка Control Plane
echo ""
echo "=== Control Plane Сертификаты ==="
check_cert "control-plane/controller-manager.crt"
check_cert "control-plane/scheduler.crt"
check_cert "control-plane/kube-proxy.crt"
check_cert "control-plane/admin.crt"

# Проверка Front Proxy
echo ""
echo "=== Front Proxy Сертификаты ==="
check_cert "front-proxy/front-proxy-client.crt"

echo ""
echo "========================================="
echo "Генерация завершена!"
echo "========================================="
```

**Пример вывода:**
```
=========================================
Проверка всех сгенерированных сертификатов
=========================================
=== CA Сертификаты ===
[OK] ca/kubernetes-ca.crt
     Subject: C = BY, ST = Minsk, L = Minsk, O = Kubernetes, OU = cluster.local, CN = kubernetes-ca
[OK] ca/etcd-ca.crt
     Subject: C = BY, ST = Minsk, L = Minsk, O = Kubernetes, OU = cluster.local, CN = etcd-ca
[OK] ca/front-proxy-ca.crt
     Subject: C = BY, ST = Minsk, L = Minsk, O = Kubernetes, OU = cluster.local, CN = front-proxy-ca

=== API Server Сертификаты ===
[OK] apiserver/apiserver.crt
     Subject: C = BY, ST = Minsk, L = Minsk, O = Kubernetes, OU = cluster.local, CN = kube-apiserver
[OK] apiserver/apiserver-kubelet-client.crt
     Subject: C = BY, ST = Minsk, L = Minsk, O = system:masters, CN = kube-apiserver-kubelet-client
[OK] apiserver/apiserver-etcd-client.crt
     Subject: C = BY, ST = Minsk, L = Minsk, O = system:masters, CN = kube-apiserver-etcd-client

=== etcd Сертификаты ===
[OK] etcd/shared/healthcheck-client.crt
     Subject: C = BY, ST = Minsk, L = Minsk, O = system:masters, CN = kube-etcd-healthcheck-client
[OK] etcd/master1/server.crt
     Subject: C = BY, ST = Minsk, L = Minsk, O = Kubernetes, CN = master1
[OK] etcd/master1/peer.crt
     Subject: C = BY, ST = Minsk, L = Minsk, O = Kubernetes, CN = master1
...

=========================================
Генерация завершена!
=========================================
```

---

## Модульное обновление

Следующие инструкции описывают как обновить только определенные компоненты без полной замены всех сертификатов.

### Модуль 1: Только API Server

**Сценарий:** Нужно добавить новый SAN в API Server сертификат или продлить только его.

```bash
cd ~/k8s-certs-manual/apiserver

# 1. Обновить API_SERVER_SANS в config.env если нужно

# 2. Регенерировать только API Server сертификат (шаги из Блока 2.1)

# 3. Применить на все master ноды
source ../config.env
for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"
  echo "[INFO] Копирование API Server сертификата на $hostname"

  scp apiserver.crt root@$ip:$K8S_PKI_DIR/apiserver.crt
  scp apiserver.key root@$ip:$K8S_PKI_DIR/apiserver.key
done

# 4. Перезапустить API Server pods на всех master нодах
for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"
  ssh root@$ip "crictl rm -f \$(crictl ps -a | grep kube-apiserver | awk '{print \$1}')"
done

# Подождать несколько секунд
sleep 10

# 5. Проверить
kubectl get nodes
```

### Модуль 2: Только etcd для одной ноды

**Сценарий:** На одной ноде повредился etcd сертификат.

**ВАЖНО:** В multi-master кластере изолированное обновление etcd сертификатов на одной ноде может привести к проблемам peer communication. Рекомендуется обновлять все ноды одновременно.

```bash
# Определить проблемную ноду
PROBLEM_NODE="master2"
PROBLEM_IP="192.168.88.192"

cd ~/k8s-certs-manual/etcd

# 1. Регенерировать сертификаты для ноды (шаги из Блока 3.2 для конкретной ноды)

# 2. Остановить etcd на проблемной ноде
source ../config.env

if [[ "$ETCD_TYPE" == "systemd" ]]; then
  ssh root@$PROBLEM_IP "systemctl stop etcd"
elif [[ "$ETCD_TYPE" == "static-pod" ]]; then
  ssh root@$PROBLEM_IP "mv /etc/kubernetes/manifests/etcd.yaml /tmp/etcd.yaml.backup"
  sleep 5
fi

# 3. Скопировать новые сертификаты
if [[ "$ETCD_TYPE" == "systemd" ]]; then
  # systemd etcd
  scp "$PROBLEM_NODE/server.crt" "root@$PROBLEM_IP:$ETCD_PKI_DIR/member-$PROBLEM_NODE.pem"
  scp "$PROBLEM_NODE/server.key" "root@$PROBLEM_IP:$ETCD_PKI_DIR/member-$PROBLEM_NODE-key.pem"
  scp "$PROBLEM_NODE/peer.crt" "root@$PROBLEM_IP:$ETCD_PKI_DIR/peer-$PROBLEM_NODE.pem"
  scp "$PROBLEM_NODE/peer.key" "root@$PROBLEM_IP:$ETCD_PKI_DIR/peer-$PROBLEM_NODE-key.pem"
else
  # static-pod etcd
  scp "$PROBLEM_NODE/server.crt" "root@$PROBLEM_IP:$ETCD_PKI_DIR/member-$PROBLEM_NODE.crt"
  scp "$PROBLEM_NODE/server.key" "root@$PROBLEM_IP:$ETCD_PKI_DIR/member-$PROBLEM_NODE.key"
  scp "$PROBLEM_NODE/peer.crt" "root@$PROBLEM_IP:$ETCD_PKI_DIR/peer-$PROBLEM_NODE.crt"
  scp "$PROBLEM_NODE/peer.key" "root@$PROBLEM_IP:$ETCD_PKI_DIR/peer-$PROBLEM_NODE.key"
fi

# 4. Установить права
ssh root@$PROBLEM_IP "chmod 700 $ETCD_PKI_DIR/*-$PROBLEM_NODE* && chown -R etcd:root $ETCD_PKI_DIR/"

# 5. Запустить etcd
if [[ "$ETCD_TYPE" == "systemd" ]]; then
  ssh root@$PROBLEM_IP "systemctl start etcd"
elif [[ "$ETCD_TYPE" == "static-pod" ]]; then
  ssh root@$PROBLEM_IP "mv /tmp/etcd.yaml.backup /etc/kubernetes/manifests/etcd.yaml"
  sleep 10
fi

# 6. Проверить health
"
  ETCDCTL_API=3 etcdctl \
    --endpoints=https://192.168.88.191:2379,https://192.168.88.192:2379,https://192.168.88.193:2379 \
    --cacert=$ETCD_PKI_DIR/ca.$ETCD_CERT_EXT \
    --cert=$ETCD_PKI_DIR/admin-master1.$ETCD_CERT_EXT \
    --key=$ETCD_PKI_DIR/admin-master1-key.$ETCD_CERT_EXT \
    endpoint health
"
```

### Модуль 3: Только Kubelet для одной ноды

**Сценарий:** Нужно обновить kubelet сертификат на конкретной ноде.

```bash
# Определить ноду
NODE="worker1"
NODE_IP="192.168.88.194"

cd ~/k8s-certs-manual/kubelet

# 1. Регенерировать kubelet сертификат (шаги из Блока 4 для конкретной ноды)

# 2. Скопировать на ноду
scp "$NODE/kubelet.crt" "root@$NODE_IP:/var/lib/kubelet/pki/kubelet.crt"
scp "$NODE/kubelet.key" "root@$NODE_IP:/var/lib/kubelet/pki/kubelet.key"

# 3. Создать kubelet-client-current.pem (объединение cert + key)
ssh root@$NODE_IP "cat /var/lib/kubelet/pki/kubelet.crt /var/lib/kubelet/pki/kubelet.key > /var/lib/kubelet/pki/kubelet-client-current.pem"
ssh root@$NODE_IP "chmod 600 /var/lib/kubelet/pki/kubelet-client-current.pem"

# 4. Перезапустить kubelet
ssh root@$NODE_IP "systemctl restart kubelet"

# 5. Проверить
sleep 5
kubectl get node $NODE
```

### Модуль 4: Только Control Plane компонент

**Сценарий:** Обновить сертификат controller manager или scheduler.

```bash
cd ~/k8s-certs-manual/control-plane

# Пример для Controller Manager

# 1. Регенерировать сертификат (шаги из Блока 5.1)

# 2. Скопировать на все master ноды
source ../config.env
for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"

  scp controller-manager.crt "root@$ip:$K8S_PKI_DIR/controller-manager.crt"
  scp controller-manager.key "root@$ip:$K8S_PKI_DIR/controller-manager.key"
done

# 3. Перезапустить controller manager pods
for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"
  ssh root@$ip "crictl rm -f \$(crictl ps -a | grep kube-controller-manager | awk '{print \$1}')"
done

# 4. Проверить
sleep 5
kubectl get pods -n kube-system | grep controller-manager
```

## Применение на кластер

Теперь применим все сгенерированные сертификаты на кластер.

**КРИТИЧЕСКИ ВАЖНО:**
- В multi-master кластере etcd сертификаты нужно применять **одновременно** на всех нодах
- Кластер будет недоступен 5-10 минут
- Убедитесь что backup создан
- Подготовьте план отката

### Полное применение для multi-master кластера

```bash
cd ~/k8s-certs-manual

# Загрузить переменные
source config.env

echo "========================================="
echo "ПРИМЕНЕНИЕ СЕРТИФИКАТОВ НА КЛАСТЕР"
echo "========================================="
echo ""
echo "ВАЖНО: Кластер будет ОСТАНОВЛЕН на 5-10 минут"
echo "Master ноды: ${#MASTER_NODES[@]}"
echo "Worker ноды: ${#WORKER_NODES[@]}"
echo ""
read -p "Продолжить? (введите YES): " confirm

if [[ "$confirm" != "YES" ]]; then
  echo "Отменено"
  exit 1
fi
```

#### Этап 1: Копирование сертификатов на все master ноды

```bash
echo "[ЭТАП 1] Копирование сертификатов на master ноды..."

for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"

  echo "=== Копирование на $hostname ($ip) ==="

  # 1. Kubernetes CA
  scp ca/kubernetes-ca.crt "root@$ip:$K8S_PKI_DIR/ca.crt"
  scp ca/kubernetes-ca.key "root@$ip:$K8S_PKI_DIR/ca.key"

  # 2. API Server сертификаты
  scp apiserver/apiserver.crt "root@$ip:$K8S_PKI_DIR/apiserver.crt"
  scp apiserver/apiserver.key "root@$ip:$K8S_PKI_DIR/apiserver.key"
  scp apiserver/apiserver-kubelet-client.crt "root@$ip:$K8S_PKI_DIR/apiserver-kubelet-client.crt"
  scp apiserver/apiserver-kubelet-client.key "root@$ip:$K8S_PKI_DIR/apiserver-kubelet-client.key"

  # 3. etcd CA и сертификаты (hostname-specific!)
  scp ca/etcd-ca.crt "root@$ip:$ETCD_PKI_DIR/ca.$ETCD_CERT_EXT"
  scp ca/etcd-ca.key "root@$ip:$ETCD_PKI_DIR/ca-key.$ETCD_CERT_EXT"

  # etcd Server
  scp "etcd/$hostname/server.crt" "root@$ip:$ETCD_PKI_DIR/member-$hostname.$ETCD_CERT_EXT"
  scp "etcd/$hostname/server.key" "root@$ip:$ETCD_PKI_DIR/member-$hostname-key.$ETCD_CERT_EXT"

  # etcd Peer
  scp "etcd/$hostname/peer.crt" "root@$ip:$ETCD_PKI_DIR/peer-$hostname.$ETCD_CERT_EXT"
  scp "etcd/$hostname/peer.key" "root@$ip:$ETCD_PKI_DIR/peer-$hostname-key.$ETCD_CERT_EXT"

  # API Server etcd client (копируется как node-hostnameX для совместимости)
  scp apiserver/apiserver-etcd-client.crt "root@$ip:$ETCD_PKI_DIR/node-$hostname.$ETCD_CERT_EXT"
  scp apiserver/apiserver-etcd-client.key "root@$ip:$ETCD_PKI_DIR/node-$hostname-key.$ETCD_CERT_EXT"

  # etcd Healthcheck client (shared)
  scp etcd/shared/healthcheck-client.crt "root@$ip:$ETCD_PKI_DIR/admin-$hostname.$ETCD_CERT_EXT"
  scp etcd/shared/healthcheck-client.key "root@$ip:$ETCD_PKI_DIR/admin-$hostname-key.$ETCD_CERT_EXT"

  # 4. Front Proxy
  scp ca/front-proxy-ca.crt "root@$ip:$K8S_PKI_DIR/front-proxy-ca.crt"
  scp ca/front-proxy-ca.key "root@$ip:$K8S_PKI_DIR/front-proxy-ca.key"
  scp front-proxy/front-proxy-client.crt "root@$ip:$K8S_PKI_DIR/front-proxy-client.crt"
  scp front-proxy/front-proxy-client.key "root@$ip:$K8S_PKI_DIR/front-proxy-client.key"

  # 5. Service Account ключи
  scp sa/sa.key "root@$ip:$K8S_PKI_DIR/sa.key"
  scp sa/sa.pub "root@$ip:$K8S_PKI_DIR/sa.pub"

  # 6. Kubelet сертификаты
  scp "kubelet/$hostname/kubelet.crt" "root@$ip:/var/lib/kubelet/pki/kubelet.crt"
  scp "kubelet/$hostname/kubelet.key" "root@$ip:/var/lib/kubelet/pki/kubelet.key"

  echo "[SUCCESS] Сертификаты скопированы на $hostname"
done
```

#### Этап 2: Установка прав на сертификаты

```bash
echo ""
echo "[ЭТАП 2] Установка прав на сертификаты..."

for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"

  echo "=== Установка прав на $hostname ==="

  ssh root@$ip "
    # Kubernetes сертификаты
    chmod 600 $K8S_PKI_DIR/*.key
    chmod 644 $K8S_PKI_DIR/*.crt
    chown -R root:root $K8S_PKI_DIR/

    # etcd сертификаты
    chmod 700 $ETCD_PKI_DIR/*-$hostname*
    chown -R etcd:root $ETCD_PKI_DIR/

    # Kubelet сертификаты
    chmod 600 /var/lib/kubelet/pki/kubelet.key
    chmod 644 /var/lib/kubelet/pki/kubelet.crt
    chown -R root:root /var/lib/kubelet/pki/
  "
done
```

#### Этап 3: Остановка кластера

**КРИТИЧЕСКИ ВАЖНО:** Остановка должна быть одновременной на всех нодах.

```bash
echo ""
echo "[ЭТАП 3] Остановка kubelet и etcd на всех master нодах..."

# Остановить kubelet на всех master нодах параллельно
for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"
  echo "[INFO] Остановка kubelet на $hostname"
  ssh root@$ip "systemctl stop kubelet" &
done
wait

sleep 5

# Остановить etcd на всех нодах параллельно
for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"
  echo "[INFO] Остановка etcd на $hostname"

  if [[ "$ETCD_TYPE" == "systemd" ]]; then
    ssh root@$ip "systemctl stop etcd" &
  elif [[ "$ETCD_TYPE" == "static-pod" ]]; then
    ssh root@$ip "mv /etc/kubernetes/manifests/etcd.yaml /tmp/etcd.yaml.backup" &
  fi
done
wait

echo "[SUCCESS] Кластер остановлен"
```

#### Этап 4: Обновление манифестов (если требуется)

```bash
echo ""
echo "[ЭТАП 4] Обновление манифестов API Server..."

# Обновить пути к etcd сертификатам в манифестах API Server
for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"

  echo "[INFO] Обновление манифеста на $hostname"

  ssh root@$ip "
    # Обновить путь к etcd client cert (hostname-specific)
    sed -i.bak 's|--etcd-certfile=.*|--etcd-certfile=$ETCD_PKI_DIR/node-$hostname.$ETCD_CERT_EXT|' /etc/kubernetes/manifests/kube-apiserver.yaml
    sed -i.bak 's|--etcd-keyfile=.*|--etcd-keyfile=$ETCD_PKI_DIR/node-$hostname-key.$ETCD_CERT_EXT|' /etc/kubernetes/manifests/kube-apiserver.yaml
  "
done
```

#### Этап 5: Создание kubelet-client-current.pem

```bash
echo ""
echo "[ЭТАП 5] Создание kubelet-client-current.pem..."

ALL_NODES=("${MASTER_NODES[@]}" "${WORKER_NODES[@]}")
for node in "${ALL_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"

  ssh root@$ip "
    cat /var/lib/kubelet/pki/kubelet.crt /var/lib/kubelet/pki/kubelet.key > /var/lib/kubelet/pki/kubelet-client-current.pem
    chmod 600 /var/lib/kubelet/pki/kubelet-client-current.pem
  "
done
```

#### Этап 6: Запуск etcd одновременно

```bash
echo ""
echo "[ЭТАП 6] Запуск etcd на всех нодах одновременно..."

for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"
  echo "[INFO] Запуск etcd на $hostname"

  if [[ "$ETCD_TYPE" == "systemd" ]]; then
    ssh root@$ip "systemctl start etcd" &
  elif [[ "$ETCD_TYPE" == "static-pod" ]]; then
    ssh root@$ip "mv /tmp/etcd.yaml.backup /etc/kubernetes/manifests/etcd.yaml" &
  fi
done
wait

echo "[INFO] Ожидание запуска etcd..."
sleep 15
```

#### Этап 7: Обновление kubeconfig файлов

```bash
echo ""
echo "[ЭТАП 7] Обновление kubeconfig файлов..."

# Определить API server endpoint
if [[ "$USE_VIP" == "true" ]]; then
  API_SERVER_ENDPOINT="$LB_VIP"
else
  # Взять IP первой master ноды
  IFS=':' read -r _ ip <<< "${MASTER_NODES[0]}"
  API_SERVER_ENDPOINT="$ip"
fi

echo "[INFO] API Server endpoint: https://$API_SERVER_ENDPOINT:6443"

for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"

  ssh root@$ip "
    # Обновить admin.conf
    kubectl config set-cluster default-cluster \
      --server=https://$API_SERVER_ENDPOINT:6443 \
      --certificate-authority=$K8S_PKI_DIR/ca.crt \
      --embed-certs=true \
      --kubeconfig=/etc/kubernetes/admin.conf

    kubectl config set-credentials default-admin \
      --client-certificate=$K8S_PKI_DIR/../control-plane/admin.crt \
      --client-key=$K8S_PKI_DIR/../control-plane/admin.key \
      --embed-certs=true \
      --kubeconfig=/etc/kubernetes/admin.conf

    # Скопировать как super-admin.conf для kube-vip
    cp /etc/kubernetes/admin.conf /etc/kubernetes/super-admin.conf

    # Обновить controller-manager.conf
    kubectl config set-cluster default-cluster \
      --server=https://$API_SERVER_ENDPOINT:6443 \
      --certificate-authority=$K8S_PKI_DIR/ca.crt \
      --embed-certs=true \
      --kubeconfig=/etc/kubernetes/controller-manager.conf

    kubectl config set-credentials default-controller-manager \
      --client-certificate=$K8S_PKI_DIR/../control-plane/controller-manager.crt \
      --client-key=$K8S_PKI_DIR/../control-plane/controller-manager.key \
      --embed-certs=true \
      --kubeconfig=/etc/kubernetes/controller-manager.conf

    # Обновить scheduler.conf
    kubectl config set-cluster default-cluster \
      --server=https://$API_SERVER_ENDPOINT:6443 \
      --certificate-authority=$K8S_PKI_DIR/ca.crt \
      --embed-certs=true \
      --kubeconfig=/etc/kubernetes/scheduler.conf

    kubectl config set-credentials default-scheduler \
      --client-certificate=$K8S_PKI_DIR/../control-plane/scheduler.crt \
      --client-key=$K8S_PKI_DIR/../control-plane/scheduler.key \
      --embed-certs=true \
      --kubeconfig=/etc/kubernetes/scheduler.conf
  "
done
```

#### Этап 8: Запуск kubelet

```bash
echo ""
echo "[ЭТАП 8] Запуск kubelet на всех master нодах..."

for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"
  echo "[INFO] Запуск kubelet на $hostname"
  ssh root@$ip "systemctl start kubelet" &
done
wait

echo "[INFO] Ожидание запуска control plane..."
sleep 30
```

#### Этап 9: Обновление worker нод

```bash
echo ""
echo "[ЭТАП 9] Обновление worker нод..."

for node in "${WORKER_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"

  echo "=== Обновление $hostname ($ip) ==="

  # Скопировать CA
  scp ca/kubernetes-ca.crt "root@$ip:$K8S_PKI_DIR/ca.crt"

  # Скопировать kubelet сертификаты
  scp "kubelet/$hostname/kubelet.crt" "root@$ip:/var/lib/kubelet/pki/kubelet.crt"
  scp "kubelet/$hostname/kubelet.key" "root@$ip:/var/lib/kubelet/pki/kubelet.key"

  # Создать kubelet-client-current.pem
  ssh root@$ip "
    cat /var/lib/kubelet/pki/kubelet.crt /var/lib/kubelet/pki/kubelet.key > /var/lib/kubelet/pki/kubelet-client-current.pem
    chmod 600 /var/lib/kubelet/pki/kubelet-client-current.pem
  "

  # Перезапустить kubelet
  ssh root@$ip "systemctl restart kubelet"

  echo "[SUCCESS] Worker нода $hostname обновлена"
done
```

#### Этап 10: Финальная проверка

```bash
echo ""
echo "[ЭТАП 10] Финальная проверка..."

sleep 10

# Обновить локальный kubeconfig
echo "[INFO] Обновление локального ~/.kube/config"
IFS=':' read -r _ master_ip <<< "${MASTER_NODES[0]}"
scp "root@$master_ip:/etc/kubernetes/admin.conf" ~/.kube/config

# Проверка нод
echo ""
echo "=== Статус нод ==="
kubectl get nodes -o wide

# Проверка pods
echo ""
echo "=== Control Plane pods ==="
kubectl get pods -n kube-system | grep -E 'apiserver|controller|scheduler|etcd'

# Проверка etcd health
echo ""
echo "=== etcd Health Check ==="
ssh root@$master_ip "
  ETCDCTL_API=3 etcdctl \
    --endpoints=https://192.168.88.191:2379,https://192.168.88.192:2379,https://192.168.88.193:2379 \
    --cacert=$ETCD_PKI_DIR/ca.$ETCD_CERT_EXT \
    --cert=$ETCD_PKI_DIR/admin-master1.$ETCD_CERT_EXT \
    --key=$ETCD_PKI_DIR/admin-master1-key.$ETCD_CERT_EXT \
    endpoint health
"

echo ""
echo "========================================="
echo "ПРИМЕНЕНИЕ ЗАВЕРШЕНО!"
echo "========================================="
```

## Проверка и тестирование

После применения сертификатов выполните тщательную проверку.

### Проверка 1: Статус нод

```bash
kubectl get nodes

# Ожидаемый вывод: Все ноды должны быть Ready
# NAME      STATUS   ROLES           AGE   VERSION
# master1   Ready    control-plane   39d   v1.32.0
# master2   Ready    control-plane   39d   v1.32.0
# master3   Ready    control-plane   39d   v1.32.0
# worker1   Ready    <none>          39d   v1.32.0
# worker2   Ready    <none>          39d   v1.32.0
```

**Если ноды в статусе NotReady:**
- Проверить логи kubelet: `ssh root@<node-ip> "journalctl -u kubelet -n 50"`
- Проверить kubelet-client-current.pem создан корректно
- Проверить сетевой плагин (CNI)

### Проверка 2: Control Plane компоненты

```bash
kubectl get pods -n kube-system

# Ожидаемый вывод: Все pods должны быть Running
# kube-apiserver-master1            1/1   Running
# kube-apiserver-master2            1/1   Running
# kube-apiserver-master3            1/1   Running
# kube-controller-manager-master1   1/1   Running
# kube-scheduler-master1            1/1   Running
# etcd-master1                      1/1   Running  (если static-pod)
```

**Если pods в CrashLoopBackOff:**
- Проверить логи: `kubectl logs -n kube-system <pod-name>`
- Для static-pod etcd: `ssh root@<master-ip> "crictl logs <container-id>"`
- Проверить правильность путей в манифестах

### Проверка 3: etcd кластер

```bash
# На master1
"
  ETCDCTL_API=3 etcdctl \
    --endpoints=https://192.168.88.191:2379,https://192.168.88.192:2379,https://192.168.88.193:2379 \
    --cacert=/etc/ssl/etcd/ssl/ca.pem \
    --cert=/etc/ssl/etcd/ssl/admin-master1.pem \
    --key=/etc/ssl/etcd/ssl/admin-master1-key.pem \
    endpoint health
"

# Ожидаемый вывод:
# https://192.168.88.191:2379 is healthy: successfully committed proposal: took = 2.456789ms
# https://192.168.88.192:2379 is healthy: successfully committed proposal: took = 2.987654ms
# https://192.168.88.193:2379 is healthy: successfully committed proposal: took = 3.123456ms

# Проверка member list
"
  ETCDCTL_API=3 etcdctl \
    --endpoints=https://192.168.88.191:2379 \
    --cacert=/etc/ssl/etcd/ssl/ca.pem \
    --cert=/etc/ssl/etcd/ssl/admin-master1.pem \
    --key=/etc/ssl/etcd/ssl/admin-master1-key.pem \
    member list
"
```

### Проверка 4: Сроки действия сертификатов

```bash
# Проверка API Server сертификата
"openssl x509 -in /etc/kubernetes/ssl/apiserver.crt -noout -dates"

# Ожидаемый вывод:
# notBefore=Jan 18 12:00:00 2025 GMT
# notAfter=Jan 18 12:00:00 2125 GMT

# Проверка всех сертификатов на master1
"
  for cert in /etc/kubernetes/ssl/*.crt /etc/ssl/etcd/ssl/*.pem; do
    if [[ -f \$cert ]]; then
      echo \"=== \$cert ===\"
      openssl x509 -in \$cert -noout -subject -dates 2>/dev/null || echo 'Not a cert'
    fi
  done
"
```

### Проверка 5: SAN в API Server сертификате

```bash
"openssl x509 -in /etc/kubernetes/ssl/apiserver.crt -noout -text | grep -A2 'Subject Alternative Name'"

# Проверить что все необходимые IP и DNS включены:
# - LB_VIP (если USE_VIP=true)
# - Все master IPs
# - ClusterIP kubernetes service (10.233.0.1)
# - Стандартные DNS имена (kubernetes, kubernetes.default, ...)
```

### Проверка 6: Доступность API через VIP

**Только если USE_VIP=true:**

```bash
# Проверка доступности через VIP
curl -k https://192.168.88.190:6443/version

# Ожидаемый вывод: JSON с версией Kubernetes
# {
#   "major": "1",
#   "minor": "32",
#   ...
# }

# Проверка через kubectl
kubectl --server=https://192.168.88.190:6443 get nodes
```

### Проверка 7: Работа приложений

```bash
# Создать тестовый pod
kubectl run test-nginx --image=nginx --restart=Never

# Подождать запуска
kubectl wait --for=condition=Ready pod/test-nginx --timeout=60s

# Проверить логи
kubectl logs test-nginx

# Удалить
kubectl delete pod test-nginx
```

### Проверка 8: Kubelet сертификаты

```bash
# Проверить на каждой ноде
for node in master1:192.168.88.191 master2:192.168.88.192 worker1:192.168.88.194; do
  IFS=':' read -r hostname ip <<< "$node"
  echo "=== $hostname ==="
  ssh root@$ip "
    openssl x509 -in /var/lib/kubelet/pki/kubelet.crt -noout -subject -dates
  "
done
```

## Troubleshooting

### Проблема 1: kubectl возвращает "x509: certificate signed by unknown authority"

**Причина:** Локальный ~/.kube/config содержит старый CA.

**Решение:**
```bash
# Скачать новый admin.conf
scp root@192.168.88.191:/etc/kubernetes/admin.conf ~/.kube/config

# Проверить
kubectl get nodes
```

### Проблема 2: Ноды в статусе NotReady

**Симптомы:**
```
NAME      STATUS     ROLES
master1   NotReady   control-plane
```

**Диагностика:**
```bash
# Проверить kubelet
ssh root@<node-ip> "systemctl status kubelet"
ssh root@<node-ip> "journalctl -u kubelet -n 50"
```

**Частые причины:**

**2.1. Kubelet получает Unauthorized**

**Логи:**
```
Unable to register node with API server: Unauthorized
```

**Решение:**
```bash
ssh root@<node-ip>
systemctl stop kubelet

# Пересоздать kubelet-client-current.pem
cat /var/lib/kubelet/pki/kubelet.crt /var/lib/kubelet/pki/kubelet.key > /var/lib/kubelet/pki/kubelet-client-current.pem
chmod 600 /var/lib/kubelet/pki/kubelet-client-current.pem

systemctl start kubelet
```

**2.2. CNI проблемы**

**Логи:**
```
NetworkReady=false reason:NetworkPluginNotReady
```

**Решение:**
Подождите 2-3 минуты для инициализации CNI плагина.

### Проблема 3: API Server в CrashLoopBackOff

**Симптомы:**
```
kube-apiserver-master2   0/1   CrashLoopBackOff
```

**Диагностика:**
```bash
ssh root@master2 "crictl logs --tail=50 \$(crictl ps -a | grep kube-apiserver | awk '{print \$1}')"
```

**Частые причины:**

**3.1. Не может подключиться к etcd**

**Логи:**
```
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

**Решение:**
```bash
# Проверить etcd client сертификаты на master2
ssh root@master2 "ls -la /etc/ssl/etcd/ssl/node-master*"

# Должны быть:
# node-master2.pem
# node-master2-key.pem

# Проверить манифест API Server
ssh root@master2 "grep etcd-certfile /etc/kubernetes/manifests/kube-apiserver.yaml"

# Должно быть:
# --etcd-certfile=/etc/ssl/etcd/ssl/node-master2.pem
```

**3.2. Неправильный SAN в API Server сертификате**

**Логи:**
```
x509: certificate is valid for ..., not <some-ip>
```

**Решение:**
Проверить SAN и регенерировать сертификат с правильным списком.

### Проблема 4: etcd не стартует

**Симптомы:**
```
Job for etcd.service failed
```

**Диагностика:**
```bash
ssh root@master1 "journalctl -u etcd -n 100"
```

**Частые причины:**

**4.1. Peer communication failure**

**Логи:**
```
remote error: tls: unknown certificate authority
```

**Причина:** Сертификаты на разных нодах несовместимы (старый CA на одной ноде, новый на другой).

**Решение:**
Убедитесь что etcd CA одинаковый на всех нодах и что сертификаты применены одновременно.

**4.2. Неправильные права на сертификаты**

**Решение:**
```bash
ssh root@master1 "
  chmod 700 /etc/ssl/etcd/ssl/*.pem
  chown -R etcd:root /etc/ssl/etcd/ssl/
"
```

### Проблема 5: kube-vip не работает (USE_VIP=true)

**Симптомы:**
```
error retrieving resource lock: Unauthorized
```

**Причина:** super-admin.conf содержит старый CA.

**Решение:**
```bash
# Обновить super-admin.conf на всех master нодах
for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"
  ssh root@$ip "cp /etc/kubernetes/admin.conf /etc/kubernetes/super-admin.conf"
done

# Перезапустить kube-vip pods
for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r _ ip <<< "$node"
  ssh root@$ip "crictl rm -f \$(crictl ps | grep kube-vip | awk '{print \$1}')"
done
```

### Проблема 6: Pods в ContainerCreating с ошибкой сертификата

**Симптомы:**
```
Failed to create pod sandbox: error getting ClusterInformation:
tls: failed to verify certificate: x509: certificate is valid for ..., not 10.233.0.1
```

**Причина:** API Server сертификат не включает ClusterIP kubernetes service.

**Решение:**
```bash
# 1. Проверить ClusterIP
kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}'
# Пример: 10.233.0.1

# 2. Проверить SAN в API Server сертификате
"openssl x509 -in /etc/kubernetes/ssl/apiserver.crt -noout -text | grep -A2 'Subject Alternative Name'"

# 3. Если ClusterIP отсутствует:
# - Добавить в API_SERVER_SANS в config.env
# - Регенерировать API Server сертификат (Блок 2.1)
# - Применить на все master ноды (Модуль 1)
```

### Проблема 7: Calico/CNI не работает

**Симптомы:**
```
calico-node   0/1   CrashLoopBackOff
```

**Решение:**
```bash
# Перезапустить Calico pods для обновления CA
kubectl delete pod -n kube-system -l k8s-app=calico-node

# Подождать
sleep 60

# Проверить
kubectl get pods -n kube-system | grep calico
```

## Откат изменений

Если после применения сертификатов возникли проблемы, выполните откат.

### Быстрый откат одной master ноды

```bash
# На проблемной ноде
NODE_IP="192.168.88.192"

ssh root@$NODE_IP "
  # Получить путь к backup
  BACKUP_DIR=\$(cat /tmp/last-backup-dir)
  echo \"Откат из: \$BACKUP_DIR\"

  # Остановить сервисы
  systemctl stop kubelet
  systemctl stop etcd || mv /etc/kubernetes/manifests/etcd.yaml /tmp/etcd.yaml.backup

  # Восстановить Kubernetes сертификаты
  rm -rf /etc/kubernetes/ssl
  cp -r \$BACKUP_DIR/kubernetes-ssl /etc/kubernetes/ssl

  # Восстановить etcd сертификаты
  rm -rf /etc/ssl/etcd
  cp -r \$BACKUP_DIR/etcd /etc/ssl/

  # Восстановить kubeconfig
  cp \$BACKUP_DIR/*.conf /etc/kubernetes/

  # Восстановить kubelet
  rm -rf /var/lib/kubelet/pki
  cp -r \$BACKUP_DIR/kubelet-pki /var/lib/kubelet/pki

  # Запустить сервисы
  systemctl start etcd || mv /tmp/etcd.yaml.backup /etc/kubernetes/manifests/etcd.yaml
  sleep 5
  systemctl start kubelet
"
```

### Полный откат всего кластера

```bash
echo "========================================="
echo "ОТКАТ ВСЕГО КЛАСТЕРА"
echo "========================================="

# Загрузить переменные
source ~/k8s-certs-manual/config.env

# 1. Остановить kubelet на всех нодах
echo "[1/7] Остановка kubelet..."
for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r _ ip <<< "$node"
  ssh root@$ip "systemctl stop kubelet" &
done
wait

sleep 5

# 2. Остановить etcd на всех нодах
echo "[2/7] Остановка etcd..."
for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r _ ip <<< "$node"
  if [[ "$ETCD_TYPE" == "systemd" ]]; then
    ssh root@$ip "systemctl stop etcd" &
  else
    ssh root@$ip "mv /etc/kubernetes/manifests/etcd.yaml /tmp/etcd.yaml.backup" &
  fi
done
wait

# 3. Восстановить сертификаты на всех master нодах
echo "[3/7] Восстановление сертификатов..."
for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"
  echo "=== Откат на $hostname ==="

  ssh root@$ip "
    BACKUP_DIR=\$(cat /tmp/last-backup-dir)

    # Kubernetes сертификаты
    rm -rf /etc/kubernetes/ssl
    cp -r \$BACKUP_DIR/kubernetes-ssl /etc/kubernetes/ssl

    # etcd сертификаты
    rm -rf /etc/ssl/etcd /etc/kubernetes/pki/etcd
    cp -r \$BACKUP_DIR/etcd /etc/ssl/ 2>/dev/null || cp -r \$BACKUP_DIR/etcd /etc/kubernetes/pki/

    # Kubeconfig
    cp \$BACKUP_DIR/*.conf /etc/kubernetes/

    # Kubelet
    rm -rf /var/lib/kubelet/pki
    cp -r \$BACKUP_DIR/kubelet-pki /var/lib/kubelet/pki

    echo \"[SUCCESS] Откат завершен на $hostname\"
  "
done

# 4. Запустить etcd одновременно
echo "[4/7] Запуск etcd..."
for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r _ ip <<< "$node"
  if [[ "$ETCD_TYPE" == "systemd" ]]; then
    ssh root@$ip "systemctl start etcd" &
  else
    ssh root@$ip "mv /tmp/etcd.yaml.backup /etc/kubernetes/manifests/etcd.yaml" &
  fi
done
wait

sleep 15

# 5. Запустить kubelet
echo "[5/7] Запуск kubelet..."
for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r _ ip <<< "$node"
  ssh root@$ip "systemctl start kubelet" &
done
wait

sleep 30

# 6. Восстановить worker ноды
echo "[6/7] Восстановление worker нод..."
for node in "${WORKER_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"

  ssh root@$ip "
    BACKUP_DIR=\$(cat /tmp/last-backup-dir)

    # CA
    cp \$BACKUP_DIR/kubernetes-ssl/ca.crt /etc/kubernetes/ssl/

    # Kubelet
    rm -rf /var/lib/kubelet/pki
    cp -r \$BACKUP_DIR/kubelet-pki /var/lib/kubelet/pki

    systemctl restart kubelet
  "
done

# 7. Проверка
echo "[7/7] Проверка после отката..."
sleep 10

# Обновить локальный kubeconfig
IFS=':' read -r _ master_ip <<< "${MASTER_NODES[0]}"
scp "root@$master_ip:/etc/kubernetes/admin.conf" ~/.kube/config

kubectl get nodes

echo "========================================="
echo "ОТКАТ ЗАВЕРШЕН"
echo "========================================="
```

## Заключение

Вы успешно регенерировали все сертификаты Kubernetes кластера вручную через OpenSSL.

**Ключевые моменты:**
- Всегда создавайте backup перед изменениями
- Применяйте etcd сертификаты одновременно на всех нодах
- Убедитесь что SAN включает все необходимые IP и DNS
- Используйте hostname-specific сертификаты для etcd
- Проверяйте права на сертификаты
- Храните plan отката на случай проблем

**Автоматизация:**

Если вам регулярно требуется регенерация сертификатов, рассмотрите использование:
- Автоматических скриптов проекта (./scripts/regenerate-all.sh)
- CFSSL для упрощения генерации
- cert-manager для автоматической ротации

**Дальнейшее чтение:**
- [CFSSL метод](cfssl.md)
- [kubeadm метод](kubeadm.md)
- [Сравнение методов](README.md)

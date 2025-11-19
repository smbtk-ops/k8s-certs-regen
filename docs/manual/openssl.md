# Ручная регенерация сертификатов Kubernetes через OpenSSL

Полное пошаговое руководство по ручному перевыпуску всех сертификатов Kubernetes кластера с использованием OpenSSL. Описаны действия руками на каждой ноде.

## Содержание

1. [Введение](#введение)
2. [Подготовка рабочего места](#подготовка-рабочего-места)
3. [Создание резервных копий](#создание-резервных-копий)
4. [Генерация новых сертификатов](#генерация-новых-сертификатов)
5. [Замена сертификатов на нодах](#замена-сертификатов-на-нодах)
6. [Перезапуск компонентов кластера](#перезапуск-компонентов-кластера)
7. [Проверка и тестирование](#проверка-и-тестирование)
8. [Troubleshooting](#troubleshooting)
9. [Откат изменений](#откат-изменений)

## Введение

Это руководство описывает **полностью ручной** процесс перевыпуска всех сертификатов Kubernetes кластера через OpenSSL. Вы будете выполнять каждое действие вручную - создавать конфигурационные файлы, генерировать сертификаты, заходить на каждую ноду, копировать файлы в нужные директории и перезапускать сервисы.

### Когда использовать OpenSSL метод

OpenSSL подходит если:
- Нужен полный контроль над всеми параметрами сертификатов
- Кластер установлен без kubeadm (Kubespray, Ansible, вручную)
- Требуются кастомные параметры (нестандартные SAN, длительный срок действия)
- Нет возможности установить дополнительные инструменты

### Информация о кластере

**Используемая конфигурация:**
- Master ноды: master1 (192.168.88.191), master2 (192.168.88.192), master3 (192.168.88.193)
- Worker ноды: worker1 (192.168.88.194), worker2 (192.168.88.195)
- HA VIP: 192.168.88.190
- Service CIDR: 10.233.0.0/18
- Pod CIDR: 10.233.64.0/18

### Требования

**Необходимо:**
- OpenSSL 1.1.1+ на локальной машине
- SSH доступ ко всем нодам кластера
- Root права на всех нодах
- Базовое понимание PKI и X.509 сертификатов

**Время выполнения:**
- Подготовка и генерация: 2-3 часа
- Применение на кластер: 1-2 часа
- Downtime кластера: 10-15 минут

## Подготовка рабочего места

### Шаг 1: Проверка OpenSSL

На вашей локальной машине проверьте версию OpenSSL:

```bash
openssl version
```

Должно показать OpenSSL 1.1.1 или выше.

### Шаг 2: Создание рабочей директории

На локальной машине создайте директорию:

```bash
mkdir -p ~/k8s-certs-manual
cd ~/k8s-certs-manual
mkdir -p ca certs configs
```

Структура:
```
k8s-certs-manual/
├── ca/         # CA сертификаты
├── certs/      # Готовые сертификаты
└── configs/    # OpenSSL конфигурации
```

## Создание резервных копий

### Шаг 3: Создание бэкапа на master1

Зайдите на master1:

```bash
ssh root@192.168.88.191
```

Создайте директорию для бэкапа:

```bash
BACKUP_DIR="/root/k8s-certs-backup-$(date +%Y%m%d_%H%M%S)"
mkdir -p $BACKUP_DIR
```

Скопируйте Kubernetes сертификаты:

```bash
cp -r /etc/kubernetes/ssl $BACKUP_DIR/kubernetes-ssl
```

Скопируйте etcd сертификаты:

```bash
cp -r /etc/ssl/etcd $BACKUP_DIR/etcd
```

Скопируйте kubeconfig файлы:

```bash
cp /etc/kubernetes/admin.conf $BACKUP_DIR/ 2>/dev/null || true
cp /etc/kubernetes/controller-manager.conf $BACKUP_DIR/ 2>/dev/null || true
cp /etc/kubernetes/scheduler.conf $BACKUP_DIR/ 2>/dev/null || true
```

Скопируйте kubelet сертификаты:

```bash
cp -r /var/lib/kubelet/pki $BACKUP_DIR/kubelet-pki
```

Проверьте бэкап:

```bash
ls -lah $BACKUP_DIR/
echo "Бэкап сохранен в: $BACKUP_DIR"
```

Выйдите:

```bash
exit
```

### Шаг 4: Создание бэкапа на master2

```bash
ssh root@192.168.88.192
BACKUP_DIR="/root/k8s-certs-backup-$(date +%Y%m%d_%H%M%S)"
mkdir -p $BACKUP_DIR
cp -r /etc/kubernetes/ssl $BACKUP_DIR/kubernetes-ssl
cp -r /etc/ssl/etcd $BACKUP_DIR/etcd
cp /etc/kubernetes/admin.conf $BACKUP_DIR/ 2>/dev/null || true
cp /etc/kubernetes/controller-manager.conf $BACKUP_DIR/ 2>/dev/null || true
cp /etc/kubernetes/scheduler.conf $BACKUP_DIR/ 2>/dev/null || true
cp -r /var/lib/kubelet/pki $BACKUP_DIR/kubelet-pki
ls -lah $BACKUP_DIR/
echo "Бэкап сохранен в: $BACKUP_DIR"
exit
```

### Шаг 5: Создание бэкапа на master3

```bash
ssh root@192.168.88.193
BACKUP_DIR="/root/k8s-certs-backup-$(date +%Y%m%d_%H%M%S)"
mkdir -p $BACKUP_DIR
cp -r /etc/kubernetes/ssl $BACKUP_DIR/kubernetes-ssl
cp -r /etc/ssl/etcd $BACKUP_DIR/etcd
cp /etc/kubernetes/admin.conf $BACKUP_DIR/ 2>/dev/null || true
cp /etc/kubernetes/controller-manager.conf $BACKUP_DIR/ 2>/dev/null || true
cp /etc/kubernetes/scheduler.conf $BACKUP_DIR/ 2>/dev/null || true
cp -r /var/lib/kubelet/pki $BACKUP_DIR/kubelet-pki
ls -lah $BACKUP_DIR/
echo "Бэкап сохранен в: $BACKUP_DIR"
exit
```

## Генерация новых сертификатов

Все действия выполняются на локальной машине в директории `~/k8s-certs-manual`.

### Часть 1: Создание Kubernetes CA

Вернитесь на локальную машину:

```bash
cd ~/k8s-certs-manual
```

Создайте конфигурационный файл для Kubernetes CA:

```bash
cat > configs/kubernetes-ca.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = v3_ca
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = Kubernetes
OU = cluster.local
CN = kubernetes-ca

[ v3_ca ]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer:always
EOF
```

Сгенерируйте приватный ключ CA:

```bash
openssl genrsa -out ca/kubernetes-ca.key 2048
```

Создайте CA сертификат (срок действия 100 лет):

```bash
openssl req -new -x509 -key ca/kubernetes-ca.key \
  -out ca/kubernetes-ca.crt \
  -days 36500 \
  -config configs/kubernetes-ca.conf
```

Проверьте созданный CA:

```bash
openssl x509 -in ca/kubernetes-ca.crt -text -noout | head -20
```

### Часть 2: Создание etcd CA

Создайте конфигурацию для etcd CA:

```bash
cat > configs/etcd-ca.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = v3_ca
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = Kubernetes
OU = cluster.local
CN = etcd-ca

[ v3_ca ]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer:always
EOF
```

Сгенерируйте etcd CA:

```bash
openssl genrsa -out ca/etcd-ca.key 2048
openssl req -new -x509 -key ca/etcd-ca.key \
  -out ca/etcd-ca.crt \
  -days 36500 \
  -config configs/etcd-ca.conf
```

### Часть 3: Создание Front Proxy CA

```bash
cat > configs/front-proxy-ca.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = v3_ca
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = Kubernetes
OU = cluster.local
CN = front-proxy-ca

[ v3_ca ]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer:always
EOF
```

Сгенерируйте Front Proxy CA:

```bash
openssl genrsa -out ca/front-proxy-ca.key 2048
openssl req -new -x509 -key ca/front-proxy-ca.key \
  -out ca/front-proxy-ca.crt \
  -days 36500 \
  -config configs/front-proxy-ca.conf
```

Проверьте все CA сертификаты:

```bash
ls -lh ca/
```

### Часть 4: API Server сертификат

Создайте конфигурацию с SAN для API Server:

```bash
cat > configs/apiserver.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = Kubernetes
OU = cluster.local
CN = kube-apiserver

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = kubernetes
DNS.2 = kubernetes.default
DNS.3 = kubernetes.default.svc
DNS.4 = kubernetes.default.svc.cluster.local
DNS.5 = cluster.local
IP.1 = 192.168.88.190
IP.2 = 192.168.88.191
IP.3 = 192.168.88.192
IP.4 = 192.168.88.193
IP.5 = 127.0.0.1
IP.6 = 10.233.0.1
EOF
```

Сгенерируйте ключ и CSR:

```bash
openssl genrsa -out certs/apiserver.key 2048
openssl req -new -key certs/apiserver.key \
  -out certs/apiserver.csr \
  -config configs/apiserver.conf
```

Подпишите сертификат Kubernetes CA:

```bash
openssl x509 -req -in certs/apiserver.csr \
  -CA ca/kubernetes-ca.crt \
  -CAkey ca/kubernetes-ca.key \
  -CAcreateserial \
  -out certs/apiserver.crt \
  -days 36500 \
  -extensions v3_req \
  -extfile configs/apiserver.conf
```

Проверьте SAN:

```bash
openssl x509 -in certs/apiserver.crt -text -noout | grep -A10 "Subject Alternative Name"
```

### Часть 5: API Server Kubelet Client

```bash
cat > configs/apiserver-kubelet-client.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = system:masters
OU = cluster.local
CN = kube-apiserver-kubelet-client

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth
EOF
```

Сгенерируйте:

```bash
openssl genrsa -out certs/apiserver-kubelet-client.key 2048
openssl req -new -key certs/apiserver-kubelet-client.key \
  -out certs/apiserver-kubelet-client.csr \
  -config configs/apiserver-kubelet-client.conf
openssl x509 -req -in certs/apiserver-kubelet-client.csr \
  -CA ca/kubernetes-ca.crt \
  -CAkey ca/kubernetes-ca.key \
  -CAcreateserial \
  -out certs/apiserver-kubelet-client.crt \
  -days 36500 \
  -extensions v3_req \
  -extfile configs/apiserver-kubelet-client.conf
```

### Часть 6: API Server etcd Client

ВАЖНО: Подписывается etcd CA!

```bash
cat > configs/apiserver-etcd-client.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = system:masters
OU = cluster.local
CN = kube-apiserver-etcd-client

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth
EOF
```

Сгенерируйте (подпись etcd CA):

```bash
openssl genrsa -out certs/apiserver-etcd-client.key 2048
openssl req -new -key certs/apiserver-etcd-client.key \
  -out certs/apiserver-etcd-client.csr \
  -config configs/apiserver-etcd-client.conf
openssl x509 -req -in certs/apiserver-etcd-client.csr \
  -CA ca/etcd-ca.crt \
  -CAkey ca/etcd-ca.key \
  -CAcreateserial \
  -out certs/apiserver-etcd-client.crt \
  -days 36500 \
  -extensions v3_req \
  -extfile configs/apiserver-etcd-client.conf
```

### Часть 7: etcd Healthcheck Client

```bash
cat > configs/etcd-healthcheck-client.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = system:masters
OU = cluster.local
CN = kube-etcd-healthcheck-client

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth
EOF
```

Сгенерируйте:

```bash
openssl genrsa -out certs/etcd-healthcheck-client.key 2048
openssl req -new -key certs/etcd-healthcheck-client.key \
  -out certs/etcd-healthcheck-client.csr \
  -config configs/etcd-healthcheck-client.conf
openssl x509 -req -in certs/etcd-healthcheck-client.csr \
  -CA ca/etcd-ca.crt \
  -CAkey ca/etcd-ca.key \
  -CAcreateserial \
  -out certs/etcd-healthcheck-client.crt \
  -days 36500 \
  -extensions v3_req \
  -extfile configs/etcd-healthcheck-client.conf
```

### Часть 8: etcd сертификаты для master1

Создайте директорию:

```bash
mkdir -p certs/etcd
```

Server сертификат для master1:

```bash
cat > configs/etcd-server-master1.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = Kubernetes
OU = cluster.local
CN = master1

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth,clientAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = master1
DNS.2 = master2
DNS.3 = master3
DNS.4 = localhost
IP.1 = 192.168.88.191
IP.2 = 192.168.88.192
IP.3 = 192.168.88.193
IP.4 = 127.0.0.1
EOF
```

Сгенерируйте:

```bash
openssl genrsa -out certs/etcd/server-master1.key 2048
openssl req -new -key certs/etcd/server-master1.key \
  -out certs/etcd/server-master1.csr \
  -config configs/etcd-server-master1.conf
openssl x509 -req -in certs/etcd/server-master1.csr \
  -CA ca/etcd-ca.crt \
  -CAkey ca/etcd-ca.key \
  -CAcreateserial \
  -out certs/etcd/server-master1.crt \
  -days 36500 \
  -extensions v3_req \
  -extfile configs/etcd-server-master1.conf
```

Peer сертификат для master1:

```bash
cat > configs/etcd-peer-master1.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = Kubernetes
OU = cluster.local
CN = master1

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth,clientAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = master1
DNS.2 = master2
DNS.3 = master3
DNS.4 = localhost
IP.1 = 192.168.88.191
IP.2 = 192.168.88.192
IP.3 = 192.168.88.193
IP.4 = 127.0.0.1
EOF
```

Сгенерируйте:

```bash
openssl genrsa -out certs/etcd/peer-master1.key 2048
openssl req -new -key certs/etcd/peer-master1.key \
  -out certs/etcd/peer-master1.csr \
  -config configs/etcd-peer-master1.conf
openssl x509 -req -in certs/etcd/peer-master1.csr \
  -CA ca/etcd-ca.crt \
  -CAkey ca/etcd-ca.key \
  -CAcreateserial \
  -out certs/etcd/peer-master1.crt \
  -days 36500 \
  -extensions v3_req \
  -extfile configs/etcd-peer-master1.conf
```

### Часть 9: etcd сертификаты для master2

Server для master2:

```bash
cat > configs/etcd-server-master2.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = Kubernetes
OU = cluster.local
CN = master2

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth,clientAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = master1
DNS.2 = master2
DNS.3 = master3
DNS.4 = localhost
IP.1 = 192.168.88.191
IP.2 = 192.168.88.192
IP.3 = 192.168.88.193
IP.4 = 127.0.0.1
EOF

openssl genrsa -out certs/etcd/server-master2.key 2048
openssl req -new -key certs/etcd/server-master2.key \
  -out certs/etcd/server-master2.csr \
  -config configs/etcd-server-master2.conf
openssl x509 -req -in certs/etcd/server-master2.csr \
  -CA ca/etcd-ca.crt \
  -CAkey ca/etcd-ca.key \
  -CAcreateserial \
  -out certs/etcd/server-master2.crt \
  -days 36500 \
  -extensions v3_req \
  -extfile configs/etcd-server-master2.conf
```

Peer для master2:

```bash
cat > configs/etcd-peer-master2.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = Kubernetes
OU = cluster.local
CN = master2

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth,clientAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = master1
DNS.2 = master2
DNS.3 = master3
DNS.4 = localhost
IP.1 = 192.168.88.191
IP.2 = 192.168.88.192
IP.3 = 192.168.88.193
IP.4 = 127.0.0.1
EOF

openssl genrsa -out certs/etcd/peer-master2.key 2048
openssl req -new -key certs/etcd/peer-master2.key \
  -out certs/etcd/peer-master2.csr \
  -config configs/etcd-peer-master2.conf
openssl x509 -req -in certs/etcd/peer-master2.csr \
  -CA ca/etcd-ca.crt \
  -CAkey ca/etcd-ca.key \
  -CAcreateserial \
  -out certs/etcd/peer-master2.crt \
  -days 36500 \
  -extensions v3_req \
  -extfile configs/etcd-peer-master2.conf
```

### Часть 10: etcd сертификаты для master3

Server для master3:

```bash
cat > configs/etcd-server-master3.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = Kubernetes
OU = cluster.local
CN = master3

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth,clientAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = master1
DNS.2 = master2
DNS.3 = master3
DNS.4 = localhost
IP.1 = 192.168.88.191
IP.2 = 192.168.88.192
IP.3 = 192.168.88.193
IP.4 = 127.0.0.1
EOF

openssl genrsa -out certs/etcd/server-master3.key 2048
openssl req -new -key certs/etcd/server-master3.key \
  -out certs/etcd/server-master3.csr \
  -config configs/etcd-server-master3.conf
openssl x509 -req -in certs/etcd/server-master3.csr \
  -CA ca/etcd-ca.crt \
  -CAkey ca/etcd-ca.key \
  -CAcreateserial \
  -out certs/etcd/server-master3.crt \
  -days 36500 \
  -extensions v3_req \
  -extfile configs/etcd-server-master3.conf
```

Peer для master3:

```bash
cat > configs/etcd-peer-master3.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = Kubernetes
OU = cluster.local
CN = master3

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth,clientAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = master1
DNS.2 = master2
DNS.3 = master3
DNS.4 = localhost
IP.1 = 192.168.88.191
IP.2 = 192.168.88.192
IP.3 = 192.168.88.193
IP.4 = 127.0.0.1
EOF

openssl genrsa -out certs/etcd/peer-master3.key 2048
openssl req -new -key certs/etcd/peer-master3.key \
  -out certs/etcd/peer-master3.csr \
  -config configs/etcd-peer-master3.conf
openssl x509 -req -in certs/etcd/peer-master3.csr \
  -CA ca/etcd-ca.crt \
  -CAkey ca/etcd-ca.key \
  -CAcreateserial \
  -out certs/etcd/peer-master3.crt \
  -days 36500 \
  -extensions v3_req \
  -extfile configs/etcd-peer-master3.conf
```

Проверьте etcd сертификаты:

```bash
ls -lh certs/etcd/
```

### Часть 11: Kubelet сертификаты

Создайте директорию:

```bash
mkdir -p certs/kubelet
```

Kubelet для master1:

```bash
cat > configs/kubelet-master1.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = system:nodes
OU = cluster.local
CN = system:node:master1

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth,serverAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = master1
IP.1 = 192.168.88.191
EOF

openssl genrsa -out certs/kubelet/kubelet-master1.key 2048
openssl req -new -key certs/kubelet/kubelet-master1.key \
  -out certs/kubelet/kubelet-master1.csr \
  -config configs/kubelet-master1.conf
openssl x509 -req -in certs/kubelet/kubelet-master1.csr \
  -CA ca/kubernetes-ca.crt \
  -CAkey ca/kubernetes-ca.key \
  -CAcreateserial \
  -out certs/kubelet/kubelet-master1.crt \
  -days 36500 \
  -extensions v3_req \
  -extfile configs/kubelet-master1.conf
```

Kubelet для master2:

```bash
cat > configs/kubelet-master2.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = system:nodes
OU = cluster.local
CN = system:node:master2

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth,serverAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = master2
IP.1 = 192.168.88.192
EOF

openssl genrsa -out certs/kubelet/kubelet-master2.key 2048
openssl req -new -key certs/kubelet/kubelet-master2.key \
  -out certs/kubelet/kubelet-master2.csr \
  -config configs/kubelet-master2.conf
openssl x509 -req -in certs/kubelet/kubelet-master2.csr \
  -CA ca/kubernetes-ca.crt \
  -CAkey ca/kubernetes-ca.key \
  -CAcreateserial \
  -out certs/kubelet/kubelet-master2.crt \
  -days 36500 \
  -extensions v3_req \
  -extfile configs/kubelet-master2.conf
```

Kubelet для master3:

```bash
cat > configs/kubelet-master3.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = system:nodes
OU = cluster.local
CN = system:node:master3

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth,serverAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = master3
IP.1 = 192.168.88.193
EOF

openssl genrsa -out certs/kubelet/kubelet-master3.key 2048
openssl req -new -key certs/kubelet/kubelet-master3.key \
  -out certs/kubelet/kubelet-master3.csr \
  -config configs/kubelet-master3.conf
openssl x509 -req -in certs/kubelet/kubelet-master3.csr \
  -CA ca/kubernetes-ca.crt \
  -CAkey ca/kubernetes-ca.key \
  -CAcreateserial \
  -out certs/kubelet/kubelet-master3.crt \
  -days 36500 \
  -extensions v3_req \
  -extfile configs/kubelet-master3.conf
```

Kubelet для worker1:

```bash
cat > configs/kubelet-worker1.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = system:nodes
OU = cluster.local
CN = system:node:worker1

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth,serverAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = worker1
IP.1 = 192.168.88.194
EOF

openssl genrsa -out certs/kubelet/kubelet-worker1.key 2048
openssl req -new -key certs/kubelet/kubelet-worker1.key \
  -out certs/kubelet/kubelet-worker1.csr \
  -config configs/kubelet-worker1.conf
openssl x509 -req -in certs/kubelet/kubelet-worker1.csr \
  -CA ca/kubernetes-ca.crt \
  -CAkey ca/kubernetes-ca.key \
  -CAcreateserial \
  -out certs/kubelet/kubelet-worker1.crt \
  -days 36500 \
  -extensions v3_req \
  -extfile configs/kubelet-worker1.conf
```

Kubelet для worker2:

```bash
cat > configs/kubelet-worker2.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = system:nodes
OU = cluster.local
CN = system:node:worker2

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth,serverAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = worker2
IP.1 = 192.168.88.195
EOF

openssl genrsa -out certs/kubelet/kubelet-worker2.key 2048
openssl req -new -key certs/kubelet/kubelet-worker2.key \
  -out certs/kubelet/kubelet-worker2.csr \
  -config configs/kubelet-worker2.conf
openssl x509 -req -in certs/kubelet/kubelet-worker2.csr \
  -CA ca/kubernetes-ca.crt \
  -CAkey ca/kubernetes-ca.key \
  -CAcreateserial \
  -out certs/kubelet/kubelet-worker2.crt \
  -days 36500 \
  -extensions v3_req \
  -extfile configs/kubelet-worker2.conf
```

### Часть 12: Control Plane компоненты

Controller Manager:

```bash
cat > configs/controller-manager.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = system:kube-controller-manager
OU = cluster.local
CN = system:kube-controller-manager

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth
EOF

openssl genrsa -out certs/controller-manager.key 2048
openssl req -new -key certs/controller-manager.key \
  -out certs/controller-manager.csr \
  -config configs/controller-manager.conf
openssl x509 -req -in certs/controller-manager.csr \
  -CA ca/kubernetes-ca.crt \
  -CAkey ca/kubernetes-ca.key \
  -CAcreateserial \
  -out certs/controller-manager.crt \
  -days 36500 \
  -extensions v3_req \
  -extfile configs/controller-manager.conf
```

Scheduler:

```bash
cat > configs/scheduler.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = system:kube-scheduler
OU = cluster.local
CN = system:kube-scheduler

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth
EOF

openssl genrsa -out certs/scheduler.key 2048
openssl req -new -key certs/scheduler.key \
  -out certs/scheduler.csr \
  -config configs/scheduler.conf
openssl x509 -req -in certs/scheduler.csr \
  -CA ca/kubernetes-ca.crt \
  -CAkey ca/kubernetes-ca.key \
  -CAcreateserial \
  -out certs/scheduler.crt \
  -days 36500 \
  -extensions v3_req \
  -extfile configs/scheduler.conf
```

Kube Proxy:

```bash
cat > configs/kube-proxy.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = system:node-proxier
OU = cluster.local
CN = system:kube-proxy

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth
EOF

openssl genrsa -out certs/kube-proxy.key 2048
openssl req -new -key certs/kube-proxy.key \
  -out certs/kube-proxy.csr \
  -config configs/kube-proxy.conf
openssl x509 -req -in certs/kube-proxy.csr \
  -CA ca/kubernetes-ca.crt \
  -CAkey ca/kubernetes-ca.key \
  -CAcreateserial \
  -out certs/kube-proxy.crt \
  -days 36500 \
  -extensions v3_req \
  -extfile configs/kube-proxy.conf
```

Admin:

```bash
cat > configs/admin.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = system:masters
OU = cluster.local
CN = kubernetes-admin

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth
EOF

openssl genrsa -out certs/admin.key 2048
openssl req -new -key certs/admin.key \
  -out certs/admin.csr \
  -config configs/admin.conf
openssl x509 -req -in certs/admin.csr \
  -CA ca/kubernetes-ca.crt \
  -CAkey ca/kubernetes-ca.key \
  -CAcreateserial \
  -out certs/admin.crt \
  -days 36500 \
  -extensions v3_req \
  -extfile configs/admin.conf
```

### Часть 13: Service Account и Front Proxy

Service Account ключи:

```bash
openssl genrsa -out certs/sa.key 2048
openssl rsa -in certs/sa.key -pubout -out certs/sa.pub
```

Front Proxy Client:

```bash
cat > configs/front-proxy-client.conf <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[ req_distinguished_name ]
C = BY
ST = Minsk
L = Minsk
O = Kubernetes
OU = cluster.local
CN = front-proxy-client

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth
EOF

openssl genrsa -out certs/front-proxy-client.key 2048
openssl req -new -key certs/front-proxy-client.key \
  -out certs/front-proxy-client.csr \
  -config configs/front-proxy-client.conf
openssl x509 -req -in certs/front-proxy-client.csr \
  -CA ca/front-proxy-ca.crt \
  -CAkey ca/front-proxy-ca.key \
  -CAcreateserial \
  -out certs/front-proxy-client.crt \
  -days 36500 \
  -extensions v3_req \
  -extfile configs/front-proxy-client.conf
```

Проверьте все сертификаты:

```bash
ls -lh ca/
ls -lh certs/
ls -lh certs/etcd/
ls -lh certs/kubelet/
```

## Замена сертификатов на нодах

### Шаг 6: Копирование сертификатов на master1

Зайдите на master1:

```bash
ssh root@192.168.88.191
```

Остановите kubelet:

```bash
systemctl stop kubelet
```

В другом терминале на локальной машине скопируйте CA сертификаты:

```bash
cd ~/k8s-certs-manual
scp ca/kubernetes-ca.crt root@192.168.88.191:/etc/kubernetes/ssl/ca.crt
scp ca/kubernetes-ca.key root@192.168.88.191:/etc/kubernetes/ssl/ca.key
```

Скопируйте API Server сертификаты:

```bash
scp certs/apiserver.crt root@192.168.88.191:/etc/kubernetes/ssl/apiserver.crt
scp certs/apiserver.key root@192.168.88.191:/etc/kubernetes/ssl/apiserver.key
scp certs/apiserver-kubelet-client.crt root@192.168.88.191:/etc/kubernetes/ssl/apiserver-kubelet-client.crt
scp certs/apiserver-kubelet-client.key root@192.168.88.191:/etc/kubernetes/ssl/apiserver-kubelet-client.key
```

Скопируйте Front Proxy:

```bash
scp ca/front-proxy-ca.crt root@192.168.88.191:/etc/kubernetes/ssl/front-proxy-ca.crt
scp ca/front-proxy-ca.key root@192.168.88.191:/etc/kubernetes/ssl/front-proxy-ca.key
scp certs/front-proxy-client.crt root@192.168.88.191:/etc/kubernetes/ssl/front-proxy-client.crt
scp certs/front-proxy-client.key root@192.168.88.191:/etc/kubernetes/ssl/front-proxy-client.key
```

Скопируйте Service Account:

```bash
scp certs/sa.key root@192.168.88.191:/etc/kubernetes/ssl/sa.key
scp certs/sa.pub root@192.168.88.191:/etc/kubernetes/ssl/sa.pub
```

Скопируйте etcd CA:

```bash
scp ca/etcd-ca.crt root@192.168.88.191:/etc/ssl/etcd/ssl/ca.pem
scp ca/etcd-ca.key root@192.168.88.191:/etc/ssl/etcd/ssl/ca-key.pem
```

Скопируйте etcd сертификаты для master1:

```bash
scp certs/etcd/server-master1.crt root@192.168.88.191:/etc/ssl/etcd/ssl/member-master1.pem
scp certs/etcd/server-master1.key root@192.168.88.191:/etc/ssl/etcd/ssl/member-master1-key.pem
scp certs/etcd/peer-master1.crt root@192.168.88.191:/etc/ssl/etcd/ssl/peer-master1.pem
scp certs/etcd/peer-master1.key root@192.168.88.191:/etc/ssl/etcd/ssl/peer-master1-key.pem
```

Скопируйте etcd client сертификаты:

```bash
scp certs/apiserver-etcd-client.crt root@192.168.88.191:/etc/ssl/etcd/ssl/node-master1.pem
scp certs/apiserver-etcd-client.key root@192.168.88.191:/etc/ssl/etcd/ssl/node-master1-key.pem
scp certs/etcd-healthcheck-client.crt root@192.168.88.191:/etc/ssl/etcd/ssl/admin-master1.pem
scp certs/etcd-healthcheck-client.key root@192.168.88.191:/etc/ssl/etcd/ssl/admin-master1-key.pem
```

Скопируйте kubelet сертификаты:

```bash
scp certs/kubelet/kubelet-master1.crt root@192.168.88.191:/var/lib/kubelet/pki/kubelet.crt
scp certs/kubelet/kubelet-master1.key root@192.168.88.191:/var/lib/kubelet/pki/kubelet.key
```

На ноде master1 установите права:

```bash
ssh root@192.168.88.191

chmod 644 /etc/kubernetes/ssl/*.crt
chmod 644 /etc/kubernetes/ssl/*.pub
chmod 600 /etc/kubernetes/ssl/*.key

chmod 640 /etc/ssl/etcd/ssl/*.pem
chown -R etcd:etcd /etc/ssl/etcd/ssl/

chmod 644 /var/lib/kubelet/pki/kubelet.crt
chmod 600 /var/lib/kubelet/pki/kubelet.key
```

Создайте объединенный файл для kubelet:

```bash
cat /var/lib/kubelet/pki/kubelet.crt /var/lib/kubelet/pki/kubelet.key > /var/lib/kubelet/pki/kubelet-client-current.pem
chmod 600 /var/lib/kubelet/pki/kubelet-client-current.pem
```

Выйдите:

```bash
exit
```

### Шаг 7: Копирование на master2

Повторите процесс для master2, заменяя master1 на master2:

```bash
ssh root@192.168.88.192
systemctl stop kubelet
exit
```

На локальной машине:

```bash
cd ~/k8s-certs-manual
scp ca/kubernetes-ca.crt root@192.168.88.192:/etc/kubernetes/ssl/ca.crt
scp ca/kubernetes-ca.key root@192.168.88.192:/etc/kubernetes/ssl/ca.key
scp certs/apiserver.crt root@192.168.88.192:/etc/kubernetes/ssl/apiserver.crt
scp certs/apiserver.key root@192.168.88.192:/etc/kubernetes/ssl/apiserver.key
scp certs/apiserver-kubelet-client.crt root@192.168.88.192:/etc/kubernetes/ssl/apiserver-kubelet-client.crt
scp certs/apiserver-kubelet-client.key root@192.168.88.192:/etc/kubernetes/ssl/apiserver-kubelet-client.key
scp ca/front-proxy-ca.crt root@192.168.88.192:/etc/kubernetes/ssl/front-proxy-ca.crt
scp ca/front-proxy-ca.key root@192.168.88.192:/etc/kubernetes/ssl/front-proxy-ca.key
scp certs/front-proxy-client.crt root@192.168.88.192:/etc/kubernetes/ssl/front-proxy-client.crt
scp certs/front-proxy-client.key root@192.168.88.192:/etc/kubernetes/ssl/front-proxy-client.key
scp certs/sa.key root@192.168.88.192:/etc/kubernetes/ssl/sa.key
scp certs/sa.pub root@192.168.88.192:/etc/kubernetes/ssl/sa.pub
scp ca/etcd-ca.crt root@192.168.88.192:/etc/ssl/etcd/ssl/ca.pem
scp ca/etcd-ca.key root@192.168.88.192:/etc/ssl/etcd/ssl/ca-key.pem
scp certs/etcd/server-master2.crt root@192.168.88.192:/etc/ssl/etcd/ssl/member-master2.pem
scp certs/etcd/server-master2.key root@192.168.88.192:/etc/ssl/etcd/ssl/member-master2-key.pem
scp certs/etcd/peer-master2.crt root@192.168.88.192:/etc/ssl/etcd/ssl/peer-master2.pem
scp certs/etcd/peer-master2.key root@192.168.88.192:/etc/ssl/etcd/ssl/peer-master2-key.pem
scp certs/apiserver-etcd-client.crt root@192.168.88.192:/etc/ssl/etcd/ssl/node-master2.pem
scp certs/apiserver-etcd-client.key root@192.168.88.192:/etc/ssl/etcd/ssl/node-master2-key.pem
scp certs/etcd-healthcheck-client.crt root@192.168.88.192:/etc/ssl/etcd/ssl/admin-master2.pem
scp certs/etcd-healthcheck-client.key root@192.168.88.192:/etc/ssl/etcd/ssl/admin-master2-key.pem
scp certs/kubelet/kubelet-master2.crt root@192.168.88.192:/var/lib/kubelet/pki/kubelet.crt
scp certs/kubelet/kubelet-master2.key root@192.168.88.192:/var/lib/kubelet/pki/kubelet.key
```

Установите права:

```bash
ssh root@192.168.88.192
chmod 644 /etc/kubernetes/ssl/*.crt
chmod 644 /etc/kubernetes/ssl/*.pub
chmod 600 /etc/kubernetes/ssl/*.key
chmod 640 /etc/ssl/etcd/ssl/*.pem
chown -R etcd:etcd /etc/ssl/etcd/ssl/
chmod 644 /var/lib/kubelet/pki/kubelet.crt
chmod 600 /var/lib/kubelet/pki/kubelet.key
cat /var/lib/kubelet/pki/kubelet.crt /var/lib/kubelet/pki/kubelet.key > /var/lib/kubelet/pki/kubelet-client-current.pem
chmod 600 /var/lib/kubelet/pki/kubelet-client-current.pem
exit
```

### Шаг 8: Копирование на master3

```bash
ssh root@192.168.88.193
systemctl stop kubelet
exit
```

На локальной машине:

```bash
cd ~/k8s-certs-manual
scp ca/kubernetes-ca.crt root@192.168.88.193:/etc/kubernetes/ssl/ca.crt
scp ca/kubernetes-ca.key root@192.168.88.193:/etc/kubernetes/ssl/ca.key
scp certs/apiserver.crt root@192.168.88.193:/etc/kubernetes/ssl/apiserver.crt
scp certs/apiserver.key root@192.168.88.193:/etc/kubernetes/ssl/apiserver.key
scp certs/apiserver-kubelet-client.crt root@192.168.88.193:/etc/kubernetes/ssl/apiserver-kubelet-client.crt
scp certs/apiserver-kubelet-client.key root@192.168.88.193:/etc/kubernetes/ssl/apiserver-kubelet-client.key
scp ca/front-proxy-ca.crt root@192.168.88.193:/etc/kubernetes/ssl/front-proxy-ca.crt
scp ca/front-proxy-ca.key root@192.168.88.193:/etc/kubernetes/ssl/front-proxy-ca.key
scp certs/front-proxy-client.crt root@192.168.88.193:/etc/kubernetes/ssl/front-proxy-client.crt
scp certs/front-proxy-client.key root@192.168.88.193:/etc/kubernetes/ssl/front-proxy-client.key
scp certs/sa.key root@192.168.88.193:/etc/kubernetes/ssl/sa.key
scp certs/sa.pub root@192.168.88.193:/etc/kubernetes/ssl/sa.pub
scp ca/etcd-ca.crt root@192.168.88.193:/etc/ssl/etcd/ssl/ca.pem
scp ca/etcd-ca.key root@192.168.88.193:/etc/ssl/etcd/ssl/ca-key.pem
scp certs/etcd/server-master3.crt root@192.168.88.193:/etc/ssl/etcd/ssl/member-master3.pem
scp certs/etcd/server-master3.key root@192.168.88.193:/etc/ssl/etcd/ssl/member-master3-key.pem
scp certs/etcd/peer-master3.crt root@192.168.88.193:/etc/ssl/etcd/ssl/peer-master3.pem
scp certs/etcd/peer-master3.key root@192.168.88.193:/etc/ssl/etcd/ssl/peer-master3-key.pem
scp certs/apiserver-etcd-client.crt root@192.168.88.193:/etc/ssl/etcd/ssl/node-master3.pem
scp certs/apiserver-etcd-client.key root@192.168.88.193:/etc/ssl/etcd/ssl/node-master3-key.pem
scp certs/etcd-healthcheck-client.crt root@192.168.88.193:/etc/ssl/etcd/ssl/admin-master3.pem
scp certs/etcd-healthcheck-client.key root@192.168.88.193:/etc/ssl/etcd/ssl/admin-master3-key.pem
scp certs/kubelet/kubelet-master3.crt root@192.168.88.193:/var/lib/kubelet/pki/kubelet.crt
scp certs/kubelet/kubelet-master3.key root@192.168.88.193:/var/lib/kubelet/pki/kubelet.key
```

Установите права:

```bash
ssh root@192.168.88.193
chmod 644 /etc/kubernetes/ssl/*.crt
chmod 644 /etc/kubernetes/ssl/*.pub
chmod 600 /etc/kubernetes/ssl/*.key
chmod 640 /etc/ssl/etcd/ssl/*.pem
chown -R etcd:etcd /etc/ssl/etcd/ssl/
chmod 644 /var/lib/kubelet/pki/kubelet.crt
chmod 600 /var/lib/kubelet/pki/kubelet.key
cat /var/lib/kubelet/pki/kubelet.crt /var/lib/kubelet/pki/kubelet.key > /var/lib/kubelet/pki/kubelet-client-current.pem
chmod 600 /var/lib/kubelet/pki/kubelet-client-current.pem
exit
```

## Перезапуск компонентов кластера

### Шаг 9: Остановка control plane

На каждой master ноде остановите API Server, Controller Manager и Scheduler.

Если используются static pods (kubeadm):

На master1:

```bash
ssh root@192.168.88.191
mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
mv /etc/kubernetes/manifests/kube-controller-manager.yaml /tmp/
mv /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/
exit
```

На master2:

```bash
ssh root@192.168.88.192
mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
mv /etc/kubernetes/manifests/kube-controller-manager.yaml /tmp/
mv /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/
exit
```

На master3:

```bash
ssh root@192.168.88.193
mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
mv /etc/kubernetes/manifests/kube-controller-manager.yaml /tmp/
mv /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/
exit
```

Если используются systemd сервисы:

```bash
ssh root@192.168.88.191
systemctl stop kube-apiserver kube-controller-manager kube-scheduler
exit

ssh root@192.168.88.192
systemctl stop kube-apiserver kube-controller-manager kube-scheduler
exit

ssh root@192.168.88.193
systemctl stop kube-apiserver kube-controller-manager kube-scheduler
exit
```

### Шаг 10: Перезапуск etcd одновременно

КРИТИЧЕСКИ ВАЖНО: etcd должен стартовать одновременно на всех нодах.

Откройте три терминала и выполните параллельно:

**Терминал 1 (master1):**
```bash
ssh root@192.168.88.191
systemctl restart etcd
```

**Терминал 2 (master2):**
```bash
ssh root@192.168.88.192
systemctl restart etcd
```

**Терминал 3 (master3):**
```bash
ssh root@192.168.88.193
systemctl restart etcd
```

Подождите 10 секунд и проверьте etcd:

```bash
ssh root@192.168.88.191
systemctl status etcd
exit
```

### Шаг 11: Запуск control plane

Если static pods:

На master1:

```bash
ssh root@192.168.88.191
mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
mv /tmp/kube-controller-manager.yaml /etc/kubernetes/manifests/
mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/
exit
```

На master2:

```bash
ssh root@192.168.88.192
mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
mv /tmp/kube-controller-manager.yaml /etc/kubernetes/manifests/
mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/
exit
```

На master3:

```bash
ssh root@192.168.88.193
mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
mv /tmp/kube-controller-manager.yaml /etc/kubernetes/manifests/
mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/
exit
```

Если systemd:

```bash
ssh root@192.168.88.191
systemctl start kube-apiserver kube-controller-manager kube-scheduler
exit

ssh root@192.168.88.192
systemctl start kube-apiserver kube-controller-manager kube-scheduler
exit

ssh root@192.168.88.193
systemctl start kube-apiserver kube-controller-manager kube-scheduler
exit
```

### Шаг 12: Запуск kubelet

```bash
ssh root@192.168.88.191
systemctl start kubelet
exit

ssh root@192.168.88.192
systemctl start kubelet
exit

ssh root@192.168.88.193
systemctl start kubelet
exit
```

### Шаг 13: Обновление kubeconfig

На локальной машине обновите admin kubeconfig:

```bash
cd ~/k8s-certs-manual
kubectl config set-cluster kubernetes \
  --certificate-authority=ca/kubernetes-ca.crt \
  --server=https://192.168.88.190:6443 \
  --embed-certs=true

kubectl config set-credentials kubernetes-admin \
  --client-certificate=certs/admin.crt \
  --client-key=certs/admin.key \
  --embed-certs=true

kubectl config set-context kubernetes-admin@kubernetes \
  --cluster=kubernetes \
  --user=kubernetes-admin

kubectl config use-context kubernetes-admin@kubernetes
```

Проверьте доступ:

```bash
kubectl get nodes
kubectl get pods -A
```

## Проверка и тестирование

### Шаг 14: Проверка сертификатов

Зайдите на master1:

```bash
ssh root@192.168.88.191
```

Проверьте срок действия API Server сертификата:

```bash
openssl x509 -in /etc/kubernetes/ssl/apiserver.crt -text -noout | grep -A2 "Validity"
```

Проверьте etcd сертификат:

```bash
openssl x509 -in /etc/ssl/etcd/ssl/member-master1.pem -text -noout | grep -A2 "Validity"
```

Выйдите:

```bash
exit
```

### Шаг 15: Проверка etcd health

```bash
ssh root@192.168.88.191
etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/admin-master1.pem \
  --key=/etc/ssl/etcd/ssl/admin-master1-key.pem \
  endpoint health
exit
```

### Шаг 16: Проверка кластера

```bash
kubectl get nodes
kubectl get pods -A
kubectl get cs
```

Создайте тестовый pod:

```bash
kubectl run test-nginx --image=nginx --restart=Never
kubectl wait --for=condition=Ready pod/test-nginx --timeout=60s
kubectl get pod test-nginx
kubectl delete pod test-nginx
```

## Troubleshooting

### Проблема: etcd не запускается

Зайдите на проблемную ноду:

```bash
ssh root@192.168.88.191
journalctl -u etcd -n 50
```

Проверьте права на сертификаты:

```bash
ls -lah /etc/ssl/etcd/ssl/
```

Убедитесь что файлы принадлежат etcd:

```bash
chown -R etcd:etcd /etc/ssl/etcd/ssl/
chmod 640 /etc/ssl/etcd/ssl/*.pem
```

### Проблема: API Server не запускается

Проверьте логи:

```bash
ssh root@192.168.88.191
crictl logs <apiserver-container-id>
# или для systemd:
journalctl -u kube-apiserver -n 50
```

Проверьте пути к сертификатам в манифесте:

```bash
cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep -A5 "tls"
```

### Проблема: kubectl не подключается

Пересоздайте kubeconfig с новыми сертификатами (см. Шаг 13).

## Откат изменений

Если возникли критические проблемы:

На master1:

```bash
ssh root@192.168.88.191
BACKUP_DIR="/root/k8s-certs-backup-YYYYMMDD_HHMMSS"  # укажите вашу директорию
systemctl stop kubelet
systemctl stop etcd
rm -rf /etc/kubernetes/ssl/*
rm -rf /etc/ssl/etcd/ssl/*
cp -r $BACKUP_DIR/kubernetes-ssl/* /etc/kubernetes/ssl/
cp -r $BACKUP_DIR/etcd/* /etc/ssl/etcd/
cp -r $BACKUP_DIR/kubelet-pki/* /var/lib/kubelet/pki/
systemctl start etcd
sleep 5
systemctl start kubelet
exit
```

Повторите для master2 и master3.

## Заключение

Вы успешно перевыпустили все сертификаты Kubernetes кластера вручную через OpenSSL. Процесс требует внимательности, но обеспечивает полный контроль над PKI инфраструктурой.

**Рекомендации:**
1. Храните CA ключи в безопасном месте
2. Документируйте все изменения
3. Планируйте следующую ротацию заранее
4. Рассмотрите автоматизацию для production

**Дополнительные материалы:**
- [CFSSL метод](cfssl.md) - альтернативный подход
- [kubeadm метод](kubeadm.md) - автоматизированный подход
- [Сравнение методов](README.md)

# Ручная регенерация сертификатов Kubernetes через CFSSL

Полное пошаговое руководство по ручному перевыпуску всех сертификатов Kubernetes кластера с использованием CFSSL. Описаны действия руками на каждой ноде.

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

Это руководство описывает **полностью ручной** процесс перевыпуска всех сертификатов Kubernetes кластера. Вы будете выполнять каждое действие вручную на каждой ноде - заходить по SSH, создавать файлы, копировать сертификаты, редактировать конфигурации и перезапускать сервисы.

### Когда использовать CFSSL метод

CFSSL подходит если:
- Нужна работа с JSON конфигурациями
- Требуется централизованное управление CA
- Планируется сложная PKI с профилями сертификатов

### Информация о кластере

**Используемая конфигурация:**
- Master ноды: master1 (192.168.88.191), master2 (192.168.88.192), master3 (192.168.88.193)
- Worker ноды: worker1 (192.168.88.194), worker2 (192.168.88.195)
- HA VIP: 192.168.88.190
- Service CIDR: 10.233.0.0/18
- Pod CIDR: 10.233.64.0/18

### Требования

**Необходимо:**
- SSH доступ ко всем нодам кластера
- Root права на всех нодах
- CFSSL установленный на рабочей машине
- Базовое понимание PKI и X.509 сертификатов
- Понимание архитектуры Kubernetes

**Время выполнения:**
- Подготовка: 30 минут
- Генерация сертификатов: 1-2 часа
- Применение на кластер: 1-2 часа
- Downtime кластера: 10-15 минут

## Подготовка рабочего места

### Шаг 1: Установка CFSSL на рабочую машину

На вашей локальной машине (не на мастере) установите CFSSL:

**Для Linux:**
```bash
CFSSL_VERSION="1.6.5"
wget https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssl_${CFSSL_VERSION}_linux_amd64
wget https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssljson_${CFSSL_VERSION}_linux_amd64
chmod +x cfssl_${CFSSL_VERSION}_linux_amd64 cfssljson_${CFSSL_VERSION}_linux_amd64
sudo mv cfssl_${CFSSL_VERSION}_linux_amd64 /usr/local/bin/cfssl
sudo mv cfssljson_${CFSSL_VERSION}_linux_amd64 /usr/local/bin/cfssljson
cfssl version
```

**Для macOS:**
```bash
brew install cfssl
cfssl version
```

Вывод должен показать версию 1.6.5 или выше.

### Шаг 2: Создание рабочей директории

На локальной машине создайте директорию для работы:

```bash
mkdir -p ~/k8s-certs-manual
cd ~/k8s-certs-manual
mkdir -p configs ca certs
```

Структура:
```
k8s-certs-manual/
├── configs/    # JSON конфигурации для CFSSL
├── ca/         # CA сертификаты
└── certs/      # Готовые сертификаты
```

## Создание резервных копий

### Шаг 3: Создание резервных копий на всех master нодах

**КРИТИЧЕСКИ ВАЖНО:** Перед любыми изменениями создайте бэкапы на каждой ноде.

#### На ноде master1 (192.168.88.191):

```bash
ssh root@192.168.88.191
```

Создайте директорию для бэкапа:

```bash
BACKUP_DIR="/root/k8s-certs-backup-$(date +%Y%m%d)"
mkdir -p $BACKUP_DIR
```

Скопируйте все сертификаты:

```bash
cp -r /etc/kubernetes/ssl $BACKUP_DIR/kubernetes-ssl
cp -r /etc/ssl/etcd $BACKUP_DIR/etcd
cp /etc/kubernetes/*.conf $BACKUP_DIR/
cp -r /var/lib/kubelet/pki $BACKUP_DIR/kubelet-pki
```

Проверьте бэкап:

```bash
ls -lah $BACKUP_DIR/
echo "Backup сохранен в: $BACKUP_DIR"
```

Выйдите с ноды:

```bash
exit
```

#### На ноде master2 (192.168.88.192):

Повторите те же действия:

```bash
ssh root@192.168.88.192
BACKUP_DIR="/root/k8s-certs-backup-$(date +%Y%m%d)"
mkdir -p $BACKUP_DIR
cp -r /etc/kubernetes/ssl $BACKUP_DIR/kubernetes-ssl
cp -r /etc/ssl/etcd $BACKUP_DIR/etcd
cp /etc/kubernetes/*.conf $BACKUP_DIR/
cp -r /var/lib/kubelet/pki $BACKUP_DIR/kubelet-pki
ls -lah $BACKUP_DIR/
echo "Backup сохранен в: $BACKUP_DIR"
exit
```

#### На ноде master3 (192.168.88.193):

```bash
ssh root@192.168.88.193
BACKUP_DIR="/root/k8s-certs-backup-$(date +%Y%m%d)"
mkdir -p $BACKUP_DIR
cp -r /etc/kubernetes/ssl $BACKUP_DIR/kubernetes-ssl
cp -r /etc/ssl/etcd $BACKUP_DIR/etcd
cp /etc/kubernetes/*.conf $BACKUP_DIR/
cp -r /var/lib/kubelet/pki $BACKUP_DIR/kubelet-pki
ls -lah $BACKUP_DIR/
echo "Backup сохранен в: $BACKUP_DIR"
exit
```

### Шаг 4: Создание конфигурации CFSSL

Вернитесь на локальную машину и создайте базовый конфиг для CFSSL.

Создайте файл `~/k8s-certs-manual/configs/ca-config.json`:

```bash
cd ~/k8s-certs-manual
cat > configs/ca-config.json <<'EOF'
{
  "signing": {
    "default": {
      "expiry": "876000h"
    },
    "profiles": {
      "kubernetes": {
        "usages": [
          "signing",
          "key encipherment",
          "server auth",
          "client auth"
        ],
        "expiry": "876000h"
      },
      "etcd": {
        "usages": [
          "signing",
          "key encipherment",
          "server auth",
          "client auth"
        ],
        "expiry": "876000h"
      }
    }
  }
}
EOF
```

Этот файл определяет профили сертификатов и срок их действия (876000 часов = 100 лет).

## Генерация новых сертификатов

Все действия выполняются на локальной машине в директории `~/k8s-certs-manual`.

### Часть 1: Генерация CA сертификатов

#### 1.1. Создание Kubernetes CA

Создайте конфигурацию для Kubernetes CA:

```bash
cd ~/k8s-certs-manual
cat > configs/kubernetes-ca-csr.json <<'EOF'
{
  "CN": "kubernetes-ca",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "Kubernetes",
      "OU": "cluster.local"
    }
  ],
  "ca": {
    "expiry": "876000h"
  }
}
EOF
```

Сгенерируйте CA сертификат:

```bash
cfssl gencert -initca configs/kubernetes-ca-csr.json | cfssljson -bare ca/kubernetes-ca
```

Проверьте созданные файлы:

```bash
ls -lh ca/kubernetes-ca*
```

Вы должны увидеть:
- `ca/kubernetes-ca.pem` - CA сертификат
- `ca/kubernetes-ca-key.pem` - приватный ключ CA
- `ca/kubernetes-ca.csr` - запрос на подпись

Проверьте содержимое сертификата:

```bash
openssl x509 -in ca/kubernetes-ca.pem -text -noout | grep -A2 "Subject:"
```

#### 1.2. Создание etcd CA

Создайте конфигурацию для etcd CA:

```bash
cat > configs/etcd-ca-csr.json <<'EOF'
{
  "CN": "etcd-ca",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "Kubernetes",
      "OU": "cluster.local"
    }
  ],
  "ca": {
    "expiry": "876000h"
  }
}
EOF
```

Сгенерируйте etcd CA:

```bash
cfssl gencert -initca configs/etcd-ca-csr.json | cfssljson -bare ca/etcd-ca
ls -lh ca/etcd-ca*
```

#### 1.3. Создание Front Proxy CA

Создайте конфигурацию:

```bash
cat > configs/front-proxy-ca-csr.json <<'EOF'
{
  "CN": "front-proxy-ca",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "Kubernetes",
      "OU": "cluster.local"
    }
  ],
  "ca": {
    "expiry": "876000h"
  }
}
EOF
```

Сгенерируйте Front Proxy CA:

```bash
cfssl gencert -initca configs/front-proxy-ca-csr.json | cfssljson -bare ca/front-proxy-ca
ls -lh ca/front-proxy-ca*
```

### Часть 2: API Server сертификаты

#### 2.1. API Server Server Certificate

Создайте конфигурацию с альтернативными именами (SAN):

```bash
cat > configs/apiserver-csr.json <<'EOF'
{
  "CN": "kube-apiserver",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "Kubernetes",
      "OU": "cluster.local"
    }
  ],
  "hosts": [
    "192.168.88.190",
    "192.168.88.191",
    "192.168.88.192",
    "192.168.88.193",
    "127.0.0.1",
    "10.233.0.1",
    "kubernetes",
    "kubernetes.default",
    "kubernetes.default.svc",
    "kubernetes.default.svc.cluster.local",
    "cluster.local"
  ]
}
EOF
```

Сгенерируйте сертификат:

```bash
cfssl gencert \
  -ca=ca/kubernetes-ca.pem \
  -ca-key=ca/kubernetes-ca-key.pem \
  -config=configs/ca-config.json \
  -profile=kubernetes \
  configs/apiserver-csr.json | cfssljson -bare certs/apiserver
```

#### 2.2. API Server Kubelet Client

```bash
cat > configs/apiserver-kubelet-client-csr.json <<'EOF'
{
  "CN": "kube-apiserver-kubelet-client",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "system:masters",
      "OU": "cluster.local"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca/kubernetes-ca.pem \
  -ca-key=ca/kubernetes-ca-key.pem \
  -config=configs/ca-config.json \
  -profile=kubernetes \
  configs/apiserver-kubelet-client-csr.json | cfssljson -bare certs/apiserver-kubelet-client
```

#### 2.3. API Server etcd Client

ВАЖНО: Подписывается etcd CA:

```bash
cat > configs/apiserver-etcd-client-csr.json <<'EOF'
{
  "CN": "kube-apiserver-etcd-client",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "system:masters",
      "OU": "cluster.local"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca/etcd-ca.pem \
  -ca-key=ca/etcd-ca-key.pem \
  -config=configs/ca-config.json \
  -profile=etcd \
  configs/apiserver-etcd-client-csr.json | cfssljson -bare certs/apiserver-etcd-client
```

### Часть 3: etcd сертификаты

#### 3.1. Healthcheck Client

```bash
cat > configs/etcd-healthcheck-client-csr.json <<'EOF'
{
  "CN": "kube-etcd-healthcheck-client",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "system:masters",
      "OU": "cluster.local"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca/etcd-ca.pem \
  -ca-key=ca/etcd-ca-key.pem \
  -config=configs/ca-config.json \
  -profile=etcd \
  configs/etcd-healthcheck-client-csr.json | cfssljson -bare certs/etcd-healthcheck-client
```

#### 3.2. Server и Peer для master1

Создайте директорию:

```bash
mkdir -p certs/etcd
```

Server сертификат для master1:

```bash
cat > configs/etcd-server-master1-csr.json <<'EOF'
{
  "CN": "master1",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "Kubernetes",
      "OU": "cluster.local"
    }
  ],
  "hosts": [
    "master1",
    "master2",
    "master3",
    "192.168.88.191",
    "192.168.88.192",
    "192.168.88.193",
    "127.0.0.1",
    "localhost"
  ]
}
EOF

cfssl gencert \
  -ca=ca/etcd-ca.pem \
  -ca-key=ca/etcd-ca-key.pem \
  -config=configs/ca-config.json \
  -profile=etcd \
  configs/etcd-server-master1-csr.json | cfssljson -bare certs/etcd/server-master1
```

Peer сертификат для master1:

```bash
cat > configs/etcd-peer-master1-csr.json <<'EOF'
{
  "CN": "master1",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "Kubernetes",
      "OU": "cluster.local"
    }
  ],
  "hosts": [
    "master1",
    "master2",
    "master3",
    "192.168.88.191",
    "192.168.88.192",
    "192.168.88.193",
    "127.0.0.1",
    "localhost"
  ]
}
EOF

cfssl gencert \
  -ca=ca/etcd-ca.pem \
  -ca-key=ca/etcd-ca-key.pem \
  -config=configs/ca-config.json \
  -profile=etcd \
  configs/etcd-peer-master1-csr.json | cfssljson -bare certs/etcd/peer-master1
```

#### 3.3. Server и Peer для master2

Server сертификат для master2:

```bash
cat > configs/etcd-server-master2-csr.json <<'EOF'
{
  "CN": "master2",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "Kubernetes",
      "OU": "cluster.local"
    }
  ],
  "hosts": [
    "master1",
    "master2",
    "master3",
    "192.168.88.191",
    "192.168.88.192",
    "192.168.88.193",
    "127.0.0.1",
    "localhost"
  ]
}
EOF

cfssl gencert \
  -ca=ca/etcd-ca.pem \
  -ca-key=ca/etcd-ca-key.pem \
  -config=configs/ca-config.json \
  -profile=etcd \
  configs/etcd-server-master2-csr.json | cfssljson -bare certs/etcd/server-master2
```

Peer сертификат для master2:

```bash
cat > configs/etcd-peer-master2-csr.json <<'EOF'
{
  "CN": "master2",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "Kubernetes",
      "OU": "cluster.local"
    }
  ],
  "hosts": [
    "master1",
    "master2",
    "master3",
    "192.168.88.191",
    "192.168.88.192",
    "192.168.88.193",
    "127.0.0.1",
    "localhost"
  ]
}
EOF

cfssl gencert \
  -ca=ca/etcd-ca.pem \
  -ca-key=ca/etcd-ca-key.pem \
  -config=configs/ca-config.json \
  -profile=etcd \
  configs/etcd-peer-master2-csr.json | cfssljson -bare certs/etcd/peer-master2
```

#### 3.4. Server и Peer для master3

Server сертификат для master3:

```bash
cat > configs/etcd-server-master3-csr.json <<'EOF'
{
  "CN": "master3",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "Kubernetes",
      "OU": "cluster.local"
    }
  ],
  "hosts": [
    "master1",
    "master2",
    "master3",
    "192.168.88.191",
    "192.168.88.192",
    "192.168.88.193",
    "127.0.0.1",
    "localhost"
  ]
}
EOF

cfssl gencert \
  -ca=ca/etcd-ca.pem \
  -ca-key=ca/etcd-ca-key.pem \
  -config=configs/ca-config.json \
  -profile=etcd \
  configs/etcd-server-master3-csr.json | cfssljson -bare certs/etcd/server-master3
```

Peer сертификат для master3:

```bash
cat > configs/etcd-peer-master3-csr.json <<'EOF'
{
  "CN": "master3",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "Kubernetes",
      "OU": "cluster.local"
    }
  ],
  "hosts": [
    "master1",
    "master2",
    "master3",
    "192.168.88.191",
    "192.168.88.192",
    "192.168.88.193",
    "127.0.0.1",
    "localhost"
  ]
}
EOF

cfssl gencert \
  -ca=ca/etcd-ca.pem \
  -ca-key=ca/etcd-ca-key.pem \
  -config=configs/ca-config.json \
  -profile=etcd \
  configs/etcd-peer-master3-csr.json | cfssljson -bare certs/etcd/peer-master3
```

### Часть 4: Kubelet сертификаты

Создайте директорию:

```bash
mkdir -p certs/kubelet
```

#### 4.1. Kubelet для master1

```bash
cat > configs/kubelet-master1-csr.json <<'EOF'
{
  "CN": "system:node:master1",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "system:nodes",
      "OU": "cluster.local"
    }
  ],
  "hosts": [
    "master1",
    "192.168.88.191"
  ]
}
EOF

cfssl gencert \
  -ca=ca/kubernetes-ca.pem \
  -ca-key=ca/kubernetes-ca-key.pem \
  -config=configs/ca-config.json \
  -profile=kubernetes \
  configs/kubelet-master1-csr.json | cfssljson -bare certs/kubelet/kubelet-master1
```

#### 4.2. Kubelet для master2

```bash
cat > configs/kubelet-master2-csr.json <<'EOF'
{
  "CN": "system:node:master2",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "system:nodes",
      "OU": "cluster.local"
    }
  ],
  "hosts": [
    "master2",
    "192.168.88.192"
  ]
}
EOF

cfssl gencert \
  -ca=ca/kubernetes-ca.pem \
  -ca-key=ca/kubernetes-ca-key.pem \
  -config=configs/ca-config.json \
  -profile=kubernetes \
  configs/kubelet-master2-csr.json | cfssljson -bare certs/kubelet/kubelet-master2
```

#### 4.3. Kubelet для master3

```bash
cat > configs/kubelet-master3-csr.json <<'EOF'
{
  "CN": "system:node:master3",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "system:nodes",
      "OU": "cluster.local"
    }
  ],
  "hosts": [
    "master3",
    "192.168.88.193"
  ]
}
EOF

cfssl gencert \
  -ca=ca/kubernetes-ca.pem \
  -ca-key=ca/kubernetes-ca-key.pem \
  -config=configs/ca-config.json \
  -profile=kubernetes \
  configs/kubelet-master3-csr.json | cfssljson -bare certs/kubelet/kubelet-master3
```

#### 4.4. Kubelet для worker1

```bash
cat > configs/kubelet-worker1-csr.json <<'EOF'
{
  "CN": "system:node:worker1",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "system:nodes",
      "OU": "cluster.local"
    }
  ],
  "hosts": [
    "worker1",
    "192.168.88.194"
  ]
}
EOF

cfssl gencert \
  -ca=ca/kubernetes-ca.pem \
  -ca-key=ca/kubernetes-ca-key.pem \
  -config=configs/ca-config.json \
  -profile=kubernetes \
  configs/kubelet-worker1-csr.json | cfssljson -bare certs/kubelet/kubelet-worker1
```

#### 4.5. Kubelet для worker2

```bash
cat > configs/kubelet-worker2-csr.json <<'EOF'
{
  "CN": "system:node:worker2",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "system:nodes",
      "OU": "cluster.local"
    }
  ],
  "hosts": [
    "worker2",
    "192.168.88.195"
  ]
}
EOF

cfssl gencert \
  -ca=ca/kubernetes-ca.pem \
  -ca-key=ca/kubernetes-ca-key.pem \
  -config=configs/ca-config.json \
  -profile=kubernetes \
  configs/kubelet-worker2-csr.json | cfssljson -bare certs/kubelet/kubelet-worker2
```

### Часть 5: Control Plane компоненты

#### 5.1. Controller Manager

```bash
cat > configs/controller-manager-csr.json <<'EOF'
{
  "CN": "system:kube-controller-manager",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "system:kube-controller-manager",
      "OU": "cluster.local"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca/kubernetes-ca.pem \
  -ca-key=ca/kubernetes-ca-key.pem \
  -config=configs/ca-config.json \
  -profile=kubernetes \
  configs/controller-manager-csr.json | cfssljson -bare certs/controller-manager
```

#### 5.2. Scheduler

```bash
cat > configs/scheduler-csr.json <<'EOF'
{
  "CN": "system:kube-scheduler",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "system:kube-scheduler",
      "OU": "cluster.local"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca/kubernetes-ca.pem \
  -ca-key=ca/kubernetes-ca-key.pem \
  -config=configs/ca-config.json \
  -profile=kubernetes \
  configs/scheduler-csr.json | cfssljson -bare certs/scheduler
```

#### 5.3. Kube Proxy

```bash
cat > configs/kube-proxy-csr.json <<'EOF'
{
  "CN": "system:kube-proxy",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "system:node-proxier",
      "OU": "cluster.local"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca/kubernetes-ca.pem \
  -ca-key=ca/kubernetes-ca-key.pem \
  -config=configs/ca-config.json \
  -profile=kubernetes \
  configs/kube-proxy-csr.json | cfssljson -bare certs/kube-proxy
```

#### 5.4. Admin

```bash
cat > configs/admin-csr.json <<'EOF'
{
  "CN": "kubernetes-admin",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "system:masters",
      "OU": "cluster.local"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca/kubernetes-ca.pem \
  -ca-key=ca/kubernetes-ca-key.pem \
  -config=configs/ca-config.json \
  -profile=kubernetes \
  configs/admin-csr.json | cfssljson -bare certs/admin
```

### Часть 6: Service Account и Front Proxy

#### 6.1. Service Account Keys

```bash
openssl genrsa -out certs/sa.key 2048
openssl rsa -in certs/sa.key -pubout -out certs/sa.pub
```

#### 6.2. Front Proxy Client

```bash
cat > configs/front-proxy-client-csr.json <<'EOF'
{
  "CN": "front-proxy-client",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "BY",
      "ST": "Minsk",
      "L": "Minsk",
      "O": "Kubernetes",
      "OU": "cluster.local"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca/front-proxy-ca.pem \
  -ca-key=ca/front-proxy-ca-key.pem \
  -config=configs/ca-config.json \
  -profile=kubernetes \
  configs/front-proxy-client-csr.json | cfssljson -bare certs/front-proxy-client
```

### Проверка всех сгенерированных сертификатов

```bash
ls -lh ca/
ls -lh certs/
ls -lh certs/etcd/
ls -lh certs/kubelet/
```

## Замена сертификатов на нодах

### Шаг 5: Копирование сертификатов на master1

Теперь перенесите сгенерированные сертификаты на ноды. Начнем с master1.

Зайдите на master1:

```bash
ssh root@192.168.88.191
```

Остановите kubelet чтобы предотвратить автоматические перезагрузки:

```bash
systemctl stop kubelet
```

Перейдите в директорию сертификатов Kubernetes:

```bash
cd /etc/kubernetes/ssl
```

На локальной машине скопируйте CA сертификаты:

```bash
scp ca/kubernetes-ca.pem root@192.168.88.191:/etc/kubernetes/ssl/ca.crt
scp ca/kubernetes-ca-key.pem root@192.168.88.191:/etc/kubernetes/ssl/ca.key
```

Скопируйте API Server сертификаты:

```bash
scp certs/apiserver.pem root@192.168.88.191:/etc/kubernetes/ssl/apiserver.crt
scp certs/apiserver-key.pem root@192.168.88.191:/etc/kubernetes/ssl/apiserver.key
scp certs/apiserver-kubelet-client.pem root@192.168.88.191:/etc/kubernetes/ssl/apiserver-kubelet-client.crt
scp certs/apiserver-kubelet-client-key.pem root@192.168.88.191:/etc/kubernetes/ssl/apiserver-kubelet-client.key
```

Скопируйте Front Proxy сертификаты:

```bash
scp ca/front-proxy-ca.pem root@192.168.88.191:/etc/kubernetes/ssl/front-proxy-ca.crt
scp ca/front-proxy-ca-key.pem root@192.168.88.191:/etc/kubernetes/ssl/front-proxy-ca.key
scp certs/front-proxy-client.pem root@192.168.88.191:/etc/kubernetes/ssl/front-proxy-client.crt
scp certs/front-proxy-client-key.pem root@192.168.88.191:/etc/kubernetes/ssl/front-proxy-client.key
```

Скопируйте Service Account ключи:

```bash
scp certs/sa.key root@192.168.88.191:/etc/kubernetes/ssl/sa.key
scp certs/sa.pub root@192.168.88.191:/etc/kubernetes/ssl/sa.pub
```

Скопируйте etcd сертификаты:

```bash
scp ca/etcd-ca.pem root@192.168.88.191:/etc/ssl/etcd/ssl/ca.pem
scp ca/etcd-ca-key.pem root@192.168.88.191:/etc/ssl/etcd/ssl/ca-key.pem
scp certs/etcd/server-master1.pem root@192.168.88.191:/etc/ssl/etcd/ssl/member-master1.pem
scp certs/etcd/server-master1-key.pem root@192.168.88.191:/etc/ssl/etcd/ssl/member-master1-key.pem
scp certs/etcd/peer-master1.pem root@192.168.88.191:/etc/ssl/etcd/ssl/peer-master1.pem
scp certs/etcd/peer-master1-key.pem root@192.168.88.191:/etc/ssl/etcd/ssl/peer-master1-key.pem
scp certs/apiserver-etcd-client.pem root@192.168.88.191:/etc/ssl/etcd/ssl/node-master1.pem
scp certs/apiserver-etcd-client-key.pem root@192.168.88.191:/etc/ssl/etcd/ssl/node-master1-key.pem
scp certs/etcd-healthcheck-client.pem root@192.168.88.191:/etc/ssl/etcd/ssl/admin-master1.pem
scp certs/etcd-healthcheck-client-key.pem root@192.168.88.191:/etc/ssl/etcd/ssl/admin-master1-key.pem
```

Скопируйте Kubelet сертификаты:

```bash
scp certs/kubelet-master1.pem root@192.168.88.191:/var/lib/kubelet/pki/kubelet.crt
scp certs/kubelet-master1-key.pem root@192.168.88.191:/var/lib/kubelet/pki/kubelet.key
```

На ноде master1 установите права:

```bash
ssh root@192.168.88.191

# Права на Kubernetes сертификаты
chmod 644 /etc/kubernetes/ssl/*.crt
chmod 644 /etc/kubernetes/ssl/*.pub
chmod 600 /etc/kubernetes/ssl/*.key

# Права на etcd сертификаты
chmod 640 /etc/ssl/etcd/ssl/*.pem
chown -R etcd:etcd /etc/ssl/etcd/ssl/

# Права на kubelet сертификаты
chmod 644 /var/lib/kubelet/pki/kubelet.crt
chmod 600 /var/lib/kubelet/pki/kubelet.key
```

Создайте объединенный файл для kubelet:

```bash
cat /var/lib/kubelet/pki/kubelet.crt /var/lib/kubelet/pki/kubelet.key > /var/lib/kubelet/pki/kubelet-client-current.pem
chmod 600 /var/lib/kubelet/pki/kubelet-client-current.pem
```

### Шаг 6: Повторите для master2 и master3

Повторите процесс копирования для master2 (192.168.88.192) и master3 (192.168.88.193), заменяя master1 на соответствующее имя ноды в путях к etcd сертификатам.

## Перезапуск компонентов кластера

### Шаг 7: Остановка control plane на всех нодах

На каждой master ноде (master1, master2, master3) выполните:

```bash
ssh root@192.168.88.191

# Остановить etcd
systemctl stop etcd

# Удалить статические поды
mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
mv /etc/kubernetes/manifests/kube-controller-manager.yaml /tmp/
mv /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/

exit
```

Повторите для master2 и master3.

### Шаг 8: Запуск etcd одновременно на всех нодах

КРИТИЧЕСКИ ВАЖНО: etcd должен стартовать одновременно на всех нодах.

Откройте три терминала и выполните команды параллельно:

**Терминал 1 (master1):**
```bash
ssh root@192.168.88.191
systemctl start etcd
```

**Терминал 2 (master2):**
```bash
ssh root@192.168.88.192
systemctl start etcd
```

**Терминал 3 (master3):**
```bash
ssh root@192.168.88.193
systemctl start etcd
```

Проверьте статус etcd:

```bash
systemctl status etcd
etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/admin-master1.pem --key=/etc/ssl/etcd/ssl/admin-master1-key.pem endpoint health
```

### Шаг 9: Запуск control plane

На каждой master ноде верните манифесты:

```bash
ssh root@192.168.88.191

mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
mv /tmp/kube-controller-manager.yaml /etc/kubernetes/manifests/
mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/

# Запустить kubelet
systemctl start kubelet

# Проверить логи
crictl ps | grep kube-apiserver
journalctl -u kubelet -f
```

Повторите для master2 и master3.

### Шаг 10: Обновление kubeconfig

На локальной машине обновите admin kubeconfig с новым сертификатом:

```bash
kubectl config set-credentials kubernetes-admin \
  --client-certificate=certs/admin.pem \
  --client-key=certs/admin-key.pem \
  --embed-certs=true
```

Проверьте доступ:

```bash
kubectl get nodes
kubectl get pods -A
```

## Проверка и тестирование

### Шаг 11: Проверка сертификатов

Проверьте срок действия новых сертификатов:

```bash
ssh root@192.168.88.191
openssl x509 -in /etc/kubernetes/ssl/apiserver.crt -text -noout | grep -A2 "Validity"
openssl x509 -in /etc/ssl/etcd/ssl/member-master1.pem -text -noout | grep -A2 "Validity"
```

### Шаг 12: Проверка работы кластера

```bash
kubectl get nodes
kubectl get pods -A
kubectl get cs
```

Создайте тестовый pod:

```bash
kubectl run test-pod --image=nginx --restart=Never
kubectl get pod test-pod
kubectl delete pod test-pod
```

## Troubleshooting

### Проблема: etcd не запускается

Проверьте логи:

```bash
journalctl -u etcd -n 50
```

Проверьте права на сертификаты:

```bash
ls -lah /etc/ssl/etcd/ssl/
```

### Проблема: API Server не запускается

Проверьте логи:

```bash
crictl logs <apiserver-container-id>
journalctl -u kubelet -n 50
```

Проверьте пути к сертификатам в манифесте:

```bash
cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep -A5 "tls"
```

### Проблема: Kubelet не подключается

Проверьте сертификат kubelet:

```bash
openssl x509 -in /var/lib/kubelet/pki/kubelet.crt -text -noout | grep "Subject:"
```

Убедитесь что CN начинается с `system:node:`:

```
Subject: O=system:nodes, CN=system:node:master1
```

## Откат изменений

Если возникли проблемы, откатите изменения с бэкапа:

```bash
ssh root@192.168.88.191

# Найдите директорию бэкапа
ls -ldt /root/k8s-certs-backup-* | head -1

# Восстановите сертификаты
BACKUP_DIR="/root/k8s-certs-backup-YYYYMMDD" # Подставить правильный путь
systemctl stop kubelet
systemctl stop etcd
cp -r $BACKUP_DIR/kubernetes-ssl/* /etc/kubernetes/ssl/
cp -r $BACKUP_DIR/etcd/* /etc/ssl/etcd/
cp -r $BACKUP_DIR/kubelet-pki/* /var/lib/kubelet/pki/
systemctl start etcd
sleep 5
systemctl start kubelet
```

Повторите для всех master нод.

## Заключение

Вы успешно перевыпустили все сертификаты Kubernetes кластера вручную, используя CFSSL. Процесс требует внимательности и точности, но обеспечивает полный контроль над PKI инфраструктурой кластера.

### Рекомендации:

1. Храните резервные копии CA ключей в безопасном месте
2. Документируйте все изменения
3. Планируйте следующую ротацию сертификатов заранее
4. Автоматизируйте процесс через CI/CD для будущих обновлений

### Дополнительные материалы:

- [OpenSSL метод](openssl.md) - альтернативный подход
- [kubeadm метод](kubeadm.md) - автоматизированный подход
- [Сравнение методов](README.md)

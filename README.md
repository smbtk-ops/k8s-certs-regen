# Kubernetes Certificates Regeneration Tool

Инструмент для полной регенерации всех сертификатов в Kubernetes multi-master HA кластере с минимальным downtime.

## Поддерживаемые конфигурации

- Multi-master HA кластеры (3+ master nodes)
- Kubespray/kubeadm установки
- etcd как systemd service
- kube-vip для HA

## Быстрый старт

### 1. Подготовка конфигурации

```bash
# Скопировать example конфиг
cp config/cluster.conf.example config/cluster.conf

# Отредактировать конфиг
vi config/cluster.conf
```

**Важные параметры в config/cluster.conf:**

```bash
# Имя кластера (из kubectl config view)
CLUSTER_NAME="cluster.local"

# Master ноды в формате hostname:IP
MASTER_NODES="master1:192.168.88.191 master2:192.168.88.192 master3:192.168.88.193"

# Worker ноды
WORKER_NODES="worker1:192.168.88.194 worker2:192.168.88.195"

# etcd ноды (обычно совпадает с MASTER_NODES)
ETCD_NODES="master1:192.168.88.191 master2:192.168.88.192 master3:192.168.88.193"

# НОВОЕ: Режим High Availability
# true  - Multi-master с VIP (kube-vip, haproxy, keepalived)
# false - Single master или multi-master без VIP
USE_VIP="true"

# Виртуальный IP (используется если USE_VIP="true")
LB_VIP="192.168.88.190"
LB_DNS="cluster.local"

# ВАЖНО: Проверить реальный ClusterIP kubernetes service
# kubectl get svc kubernetes -o yaml | grep clusterIP
# Значение должно быть включено в API_SERVER_SANS
SERVICE_CIDR="10.233.0.0/18"
API_SERVER_SANS="... 10.233.0.1"

# Срок действия сертификатов в днях (36500 = 100 лет)
CERT_VALIDITY_DAYS=36500

# SSH настройки
SSH_KEY_PATH="~/.ssh/id_ed25519"
SSH_USER="root"
```

**Примеры конфигурации для разных сценариев:**

**Сценарий 1: Multi-master HA кластер с kube-vip**
```bash
USE_VIP="true"
LB_VIP="192.168.88.190"
LB_DNS="cluster.local"
MASTER_NODES="master1:192.168.88.191 master2:192.168.88.192 master3:192.168.88.193"
```
Скрипт автоматически добавит `LB_VIP` в SAN сертификата API server.
Admin kubeconfig будет использовать `https://192.168.88.190:6443`.

**Сценарий 2: Single master кластер**
```bash
USE_VIP="false"
LB_VIP=""
LB_DNS=""
MASTER_NODES="master1:192.168.88.191"
MASTER_IP="192.168.88.191"
```
Admin kubeconfig будет использовать `https://192.168.88.191:6443`.

**Сценарий 3: Multi-master с DNS балансировкой (без VIP)**
```bash
USE_VIP="true"
LB_VIP="api.cluster.local"  # DNS имя вместо IP
LB_DNS="api.cluster.local"
```
Скрипт добавит DNS имя в SAN сертификата.

### 2. Генерация сертификатов

```bash
./scripts/regenerate-all.sh
```

Скрипт сгенерирует все сертификаты в директорию `certs/`:
- CA сертификаты (Kubernetes CA, etcd CA, front-proxy CA)
- API Server сертификаты
- etcd сертификаты для всех master нод  
- Kubelet сертификаты для всех нод
- Controller Manager, Scheduler, Proxy сертификаты
- Admin kubeconfig
- Service Account ключи
- Front Proxy сертификаты

### 3. Проверка сертификатов (опционально)

```bash
./scripts/verify-certs.sh
```

### 4. Применение сертификатов на кластер

```bash
./scripts/apply-all-at-once.sh
```

**КРИТИЧЕСКИ ВАЖНО:**
- Весь кластер будет ОСТАНОВЛЕН
- Downtime: 5-10 минут
- Требует ввода `YES` для подтверждения
- Рекомендуется запускать в maintenance window
- Обязательно должен быть BACKUP

**Что делает скрипт:**

1. Подготовка и копирование сертификатов на все ноды
2. Создание автоматического backup на каждой ноде
3. Остановка kubelet и etcd на всех master нодах
4. Применение новых сертификатов (K8s + etcd)
5. Одновременный запуск etcd кластера на всех нодах
6. Обновление kubeconfig файлов с новым CA
7. Запуск kubelet и перезапуск control plane компонентов
8. Обновление kubelet сертификатов на всех нодах
9. Финальная проверка работоспособности

### 5. Финальная проверка

```bash
# Проверка нод
kubectl get nodes

# Проверка всех pods
kubectl get pods -A

# Проверка etcd health (запускать с master1)
ssh root@192.168.88.191 "
  ETCDCTL_API=3 etcdctl \
    --endpoints=https://192.168.88.191:2379,https://192.168.88.192:2379,https://192.168.88.193:2379 \
    --cacert=/etc/ssl/etcd/ssl/ca.pem \
    --cert=/etc/ssl/etcd/ssl/admin-master1.pem \
    --key=/etc/ssl/etcd/ssl/admin-master1-key.pem \
    endpoint health
"

# Проверка срока действия сертификата
openssl x509 -in /etc/kubernetes/ssl/apiserver.crt -noout -dates
```

## Структура проекта

```
k8s-certs-regen/
├── config/
│   ├── cluster.conf.example    # Пример конфигурации с комментариями
│   └── cluster.conf             # Ваша конфигурация (создается вами)
├── scripts/
│   ├── common.sh               # Общие функции
│   ├── regenerate-all.sh       # ГЛАВНЫЙ: генерация всех сертификатов
│   ├── apply-all-at-once.sh    # ГЛАВНЫЙ: применение на кластер
│   ├── verify-certs.sh         # Проверка сертификатов
│   ├── backup-certs.sh         # Ручной backup
│   ├── apply-kubeconfigs.sh    # Обновление kubeconfig (вызывается автоматически)
│   ├── generate-*.sh           # Генераторы отдельных типов сертификатов
├── certs/                       # Сгенерированные сертификаты (создается автоматически)
└── docs/
    ├── certificate-types.md     # Описание типов сертификатов
    └── troubleshooting.md       # Решение типичных проблем
```

## Типичные проблемы и решения

### Проблема 1: kubectl не подключается после применения

**Симптомы:**
```
Unable to connect to the server: x509: certificate signed by unknown authority
```

**Причина:** Локальный ~/.kube/config содержит старый CA

**Решение:**
```bash
# Скачать новый kubeconfig с master ноды
scp -i ~/.ssh/id_ed25519 root@192.168.88.191:/etc/kubernetes/admin.conf ~/.kube/config
```

### Проблема 2: Ноды в статусе NotReady

**Симптомы:**
```
NAME      STATUS     ROLES
master1   NotReady   control-plane
```

**Причина:** Kubelet не обновил клиентский сертификат

**Решение:**
Скрипт `apply-all-at-once.sh` автоматически создает правильный `kubelet-client-current.pem`.  
Если проблема все равно есть, вручную на проблемной ноде:

```bash
ssh root@<node-ip>
systemctl stop kubelet
cat /var/lib/kubelet/pki/kubelet.crt /var/lib/kubelet/pki/kubelet.key > /var/lib/kubelet/pki/kubelet-client-current.pem
chmod 600 /var/lib/kubelet/pki/kubelet-client-current.pem
systemctl start kubelet
```

### Проблема 3: API server в CrashLoopBackOff на master2/master3

**Симптомы:**
```
kube-apiserver-master2   0/1   CrashLoopBackOff
```

**Логи показывают:**
```
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

**Причина:** API server не может подключиться к etcd из-за неправильных сертификатов.

**Решение:**
```bash
# ВАЖНО: Скрипт apply-all-at-once.sh использует hostname-specific имена для сертификатов
# После работы скрипта каждая нода использует свой файл:
# master1: /etc/ssl/etcd/ssl/node-master1.pem
# master2: /etc/ssl/etcd/ssl/node-master2.pem
# master3: /etc/ssl/etcd/ssl/node-master3.pem

# Если нужно исправить вручную, скопируйте сертификаты с правильными именами:
scp -i ~/.ssh/id_ed25519 certs/apiserver/apiserver-etcd-client.crt root@192.168.88.192:/etc/ssl/etcd/ssl/node-master2.pem
scp -i ~/.ssh/id_ed25519 certs/apiserver/apiserver-etcd-client.key root@192.168.88.192:/etc/ssl/etcd/ssl/node-master2-key.pem

ssh root@192.168.88.192 "chmod 700 /etc/ssl/etcd/ssl/node-master2*.pem && chown etcd:root /etc/ssl/etcd/ssl/node-master2*.pem"

# Повторить для master3
scp -i ~/.ssh/id_ed25519 certs/apiserver/apiserver-etcd-client.crt root@192.168.88.193:/etc/ssl/etcd/ssl/node-master3.pem
scp -i ~/.ssh/id_ed25519 certs/apiserver/apiserver-etcd-client.key root@192.168.88.193:/etc/ssl/etcd/ssl/node-master3-key.pem

ssh root@192.168.88.193 "chmod 700 /etc/ssl/etcd/ssl/node-master3*.pem && chown etcd:root /etc/ssl/etcd/ssl/node-master3*.pem"

# Убедитесь что манифест API server использует правильный путь к сертификату
ssh root@192.168.88.192 "grep 'etcd-certfile' /etc/kubernetes/manifests/kube-apiserver.yaml"
# Должно быть: --etcd-certfile=/etc/ssl/etcd/ssl/node-master2.pem

# Перезапустить API server pods
ssh root@192.168.88.192 "crictl rm -f \$(crictl ps -a | grep kube-apiserver | awk '{print \$1}')"
ssh root@192.168.88.193 "crictl rm -f \$(crictl ps -a | grep kube-apiserver | awk '{print \$1}')"
```

**Примечание:** Скрипт `apply-all-at-once.sh` делает это автоматически и обновляет манифесты. Эта инструкция для ручного исправления.

### Проблема 4: etcd не стартует после обновления

**Симптомы:**
```
Job for etcd.service failed
```

**Причина:** В multi-master etcd требует, чтобы ВСЕ ноды имели согласованные сертификаты для peer communication

**Решение:**
- **ВСЕГДА** используйте `apply-all-at-once.sh` для multi-master
- Никогда не обновляйте ноды последовательно
- Скрипт останавливает etcd на всех нодах, применяет сертификаты и запускает одновременно

### Проблема 5: kube-vip не может получить leader lease

**Симптомы:**
```
error retrieving resource lock: Unauthorized
```

**Причина:** kube-vip использует `/etc/kubernetes/super-admin.conf` который содержит старый CA или клиентский сертификат

**Решение:**
Скрипт `apply-kubeconfigs.sh` (вызывается автоматически из `apply-all-at-once.sh`) обновляет все kubeconfig файлы, включая `super-admin.conf`.

### Проблема 6: Pods в ContainerCreating с ошибкой сертификата

**Симптомы:**
```
calico-kube-controllers   0/1   ContainerCreating
```

**Логи:**
```
tls: failed to verify certificate: x509: certificate is valid for ... 10.96.0.1, not 10.233.0.1
```

**Причина:** API server сертификат не включает реальный ClusterIP kubernetes service

**Решение:**
```bash
# 1. Проверить реальный ClusterIP
kubectl get svc kubernetes -o yaml | grep clusterIP

# 2. Обновить config/cluster.conf с правильным IP в API_SERVER_SANS

# 3. Перегенерировать API server сертификаты
./scripts/generate-apiserver.sh

# 4. Скрипт apply-all-at-once.sh автоматически применяет новые сертификаты
```

**Примечание:** Скрипт `apply-all-at-once.sh` теперь автоматически перезапускает Calico pods для обновления CA.

## Откат изменений

На каждой ноде автоматически создается backup в `/root/k8s-certs-backup-<timestamp>`.  
Путь сохранен в `/tmp/last-backup-dir`.

### Откат на одной ноде:

```bash
ssh root@<node-ip>
BACKUP_DIR=$(cat /tmp/last-backup-dir)
systemctl stop kubelet
systemctl stop etcd

# Восстановление сертификатов
rm -rf /etc/kubernetes/ssl
cp -r $BACKUP_DIR/kubernetes-ssl /etc/kubernetes/ssl

rm -rf /etc/ssl/etcd
cp -r $BACKUP_DIR/etcd /etc/ssl/

# Восстановление kubeconfig
cp $BACKUP_DIR/*.conf /etc/kubernetes/

# Восстановление kubelet
rm -rf /var/lib/kubelet/pki
cp -r $BACKUP_DIR/kubelet-pki /var/lib/kubelet/pki

# Запуск сервисов
systemctl start etcd
sleep 5
systemctl start kubelet
```

### Откат всего кластера:

Функция `rollback_all()` встроена в `apply-all-at-once.sh` и вызывается автоматически при ошибках.

## Требования

- OpenSSL
- kubectl
- SSH доступ ко всем нодам
- Root права на всех нодах
- Достаточное место на диске для backup

## Важные замечания

1. **ОБЯЗАТЕЛЬНО создайте backup перед применением**
   Скрипт создает автоматический backup на каждой ноде

2. **Планируйте maintenance window**
   Кластер будет недоступен 5-10 минут

3. **Срок действия сертификатов**
   По умолчанию 10 лет, можно настроить в `CERT_VALIDITY_DAYS`

4. **Multi-master особенность**
   etcd требует одновременного обновления всех master нод

5. **Worker ноды**
   Обновляются автоматически в конце процесса

6. **Именование сертификатов etcd**
   Каждая master нода использует hostname-specific сертификаты:
   - master1: `node-master1.pem`, `member-master1.pem`, `admin-master1.pem`
   - master2: `node-master2.pem`, `member-master2.pem`, `admin-master2.pem`
   - master3: `node-master3.pem`, `member-master3.pem`, `admin-master3.pem`

7. **Режим VIP**
   - Установите `USE_VIP="true"` для multi-master с VIP (kube-vip, haproxy)
   - Установите `USE_VIP="false"` для single-master или без VIP
   - Если `USE_VIP="true"`, то `LB_VIP` автоматически добавляется в SAN сертификата
   - Admin kubeconfig использует VIP или MASTER_IP в зависимости от `USE_VIP`

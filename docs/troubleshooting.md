# Troubleshooting Guide

Полное руководство по решению проблем при регенерации сертификатов в multi-master Kubernetes кластерах.

## Важная информация о структуре сертификатов

После работы скрипта `apply-all-at-once.sh` каждая master нода использует **hostname-specific** сертификаты etcd.

### Для etcd systemd (Kubespray)

**Структура на master1:**
```
/etc/ssl/etcd/ssl/
├── ca.pem                       # общий CA для всех нод
├── ca-key.pem                   # общий CA key для всех нод
├── member-master1.pem           # etcd server cert для master1
├── member-master1-key.pem
├── node-master1.pem             # etcd client cert для API server на master1
├── node-master1-key.pem
├── admin-master1.pem            # etcd admin cert для etcdctl на master1
└── admin-master1-key.pem
```

**Манифест API Server** на каждой ноде обновляется автоматически:
- master1: `--etcd-certfile=/etc/ssl/etcd/ssl/node-master1.pem`
- master2: `--etcd-certfile=/etc/ssl/etcd/ssl/node-master2.pem`
- master3: `--etcd-certfile=/etc/ssl/etcd/ssl/node-master3.pem`

### Для etcd static-pod (kubeadm)

**Структура на master1:**
```
/etc/kubernetes/pki/etcd/
├── ca.crt                       # общий CA для всех нод
├── ca.key                       # общий CA key для всех нод
├── member-master1.crt           # etcd server cert для master1
├── member-master1.key
├── node-master1.crt             # etcd client cert для API server на master1
├── node-master1.key
├── admin-master1.crt            # etcd admin cert для etcdctl на master1
└── admin-master1.key
```

**Манифест API Server** на каждой ноде обновляется автоматически:
- master1: `--etcd-certfile=/etc/kubernetes/pki/etcd/node-master1.crt`
- master2: `--etcd-certfile=/etc/kubernetes/pki/etcd/node-master2.crt`
- master3: `--etcd-certfile=/etc/kubernetes/pki/etcd/node-master3.crt`

**Структура на master2/master3:** Аналогично с заменой master1 на master2/master3 в именах файлов.

**Ключевой момент:** Каждая нода имеет ТОЛЬКО свои сертификаты, а не сертификаты всех нод.

## Содержание

1. [Проблемы конфигурации](#проблемы-конфигурации)
2. [Проблемы при генерации](#проблемы-при-генерации)
3. [Проблемы при применении](#проблемы-при-применении)
4. [Проблемы после применения](#проблемы-после-применения)
5. [Проблемы с etcd](#проблемы-с-etcd)
6. [Проблемы с кластером](#проблемы-с-кластером)

## Проблемы конфигурации

### Ошибка: "USE_VIP должен быть 'true' или 'false'"

**Полное сообщение:**
```
[ERROR] USE_VIP должен быть 'true' или 'false', получено: 'yes'
```

**Причина:** Неправильное значение в USE_VIP

**Решение:**
```bash
# В config/cluster.conf используйте только:
USE_VIP="true"   # для кластера с VIP
# ИЛИ
USE_VIP="false"  # для кластера без VIP
```

Допустимые значения: `true`, `false`, `yes`, `no`, `1`, `0` (регистр не важен)

### Ошибка: "USE_VIP=true, но LB_VIP не указан"

**Полное сообщение:**
```
[ERROR] USE_VIP=true, но LB_VIP не указан
[ERROR] Укажите LB_VIP в config/cluster.conf или установите USE_VIP=false
```

**Причина:** Включен режим HA с VIP, но виртуальный IP не указан

**Решение:**
```bash
# Вариант 1: Указать VIP
USE_VIP="true"
LB_VIP="192.168.88.190"

# Вариант 2: Отключить режим VIP
USE_VIP="false"
LB_VIP=""
```

### Предупреждение: "LB_VIP будет проигнорирован"

**Полное сообщение:**
```
[WARNING] USE_VIP=false, но LB_VIP указан (192.168.88.190)
[WARNING] LB_VIP будет проигнорирован, используется MASTER_IP: 192.168.88.191
```

**Причина:** Указан VIP, но режим HA отключен

**Объяснение:** Это предупреждение, не ошибка. Скрипт использует MASTER_IP вместо LB_VIP.

**Решение (опционально):**
```bash
# Очистить неиспользуемую переменную для чистоты конфига
LB_VIP=""
LB_DNS=""
```

### Ошибка: "ETCD_TYPE должен быть 'auto', 'systemd' или 'static-pod'"

**Полное сообщение:**
```
[ERROR] ETCD_TYPE должен быть 'auto', 'systemd' или 'static-pod', получено: 'docker'
```

**Причина:** Неправильное значение в ETCD_TYPE

**Решение:**
```bash
# В config/cluster.conf используйте только:
ETCD_TYPE="auto"        # Автоматическое определение (рекомендуется)
# ИЛИ
ETCD_TYPE="systemd"     # Явно указать systemd (Kubespray)
# ИЛИ
ETCD_TYPE="static-pod"  # Явно указать static pod (kubeadm)
```

**Как определить тип вручную:**
```bash
# Проверить systemd
ssh root@master1 "systemctl status etcd"
# Если работает → ETCD_TYPE="systemd"

# Проверить static pod
ssh root@master1 "ls /etc/kubernetes/manifests/etcd.yaml"
# Если файл есть → ETCD_TYPE="static-pod"
```

### Ошибка: "Не удалось определить тип etcd"

**Полное сообщение:**
```
[INFO] ETCD_TYPE=auto, определяем тип автоматически...
[ERROR] Не удалось определить тип etcd на 192.168.88.191
[ERROR] Проверьте что etcd запущен на этой ноде
```

**Причина:** etcd не запущен или используется нестандартный способ развертывания

**Решение:**
```bash
# 1. Проверить что etcd работает
ssh root@192.168.88.191 "systemctl status etcd"  # для systemd
ssh root@192.168.88.191 "crictl ps | grep etcd"  # для static-pod

# 2. Если etcd работает, но не определяется автоматически:
# Явно укажите тип в config/cluster.conf
ETCD_TYPE="systemd"  # или "static-pod"
```

### Проблема: kubectl подключается, но VIP не работает

**Симптомы:**
```
# С master IP работает
kubectl --server=https://192.168.88.191:6443 get nodes

# С VIP не работает
kubectl --server=https://192.168.88.190:6443 get nodes
Error: x509: certificate is valid for ..., not 192.168.88.190
```

**Причина:** USE_VIP был установлен в `false` при генерации сертификатов, VIP не добавлен в SAN

**Решение:**
```bash
# 1. Установить USE_VIP=true
echo 'USE_VIP="true"' >> config/cluster.conf

# 2. Перегенерировать API server сертификаты
./scripts/generate-apiserver.sh

# 3. Скопировать на все master ноды
for ip in 192.168.88.191 192.168.88.192 192.168.88.193; do
  scp -i ~/.ssh/id_ed25519 certs/apiserver/apiserver.crt root@$ip:/etc/kubernetes/ssl/
  scp -i ~/.ssh/id_ed25519 certs/apiserver/apiserver.key root@$ip:/etc/kubernetes/ssl/
  ssh -i ~/.ssh/id_ed25519 root@$ip "crictl rm -f \$(crictl ps -a | grep kube-apiserver | awk '{print \$1}')"
done

# 4. Проверить SAN в сертификате
ssh root@192.168.88.191 "openssl x509 -in /etc/kubernetes/ssl/apiserver.crt -noout -text | grep -A1 'Subject Alternative Name'"
```

## Проблемы при генерации

### Ошибка: "Missing SA keys"

**Полное сообщение:**
```
cp: /path/to/certs/sa/sa.key: No such file or directory
```

**Причина:** Service Account ключи не сгенерированы

**Решение:**
```bash
./scripts/generate-sa-keys.sh
```

### Ошибка: "Missing front-proxy certificates"

**Полное сообщение:**
```
cp: /path/to/certs/apiserver/front-proxy-client.crt: No such file or directory
```

**Причина:** Front-proxy сертификаты не сгенерированы или неправильный путь

**Решение:**
```bash
# Генерация front-proxy сертификатов
./scripts/generate-front-proxy.sh

# Проверка что они в правильной директории
ls -la certs/front-proxy/
```

### Ошибка: "Kubelet certs only for master1"

**Проблема:** Сгенерированы сертификаты только для одной master ноды

**Причина:** Скрипт `generate-kubelet.sh` не итерирует по всем MASTER_NODES

**Проверка:**
```bash
ls -la certs/kubelet/
# Должны быть директории для всех master и worker нод
```

## Проблемы при применении

### Ошибка: "Cannot connect to remote host"

**Симптомы:**
```
ssh: connect to host 192.168.88.191 port 22: Connection refused
```

**Причины:**
1. SSH ключ неправильный
2. Firewall блокирует соединение
3. SSH сервис не запущен

**Решение:**
```bash
# Проверка SSH ключа
ssh -i ~/.ssh/id_ed25519 root@192.168.88.191 "echo OK"

# Проверка что ключ добавлен в ssh-agent
ssh-add ~/.ssh/id_ed25519

# Проверка firewall
# На удаленной ноде:
sudo ufw status
sudo firewall-cmd --list-all
```

### Ошибка: "Permission denied" при копировании

**Симптомы:**
```
scp: /etc/kubernetes/ssl/ca.crt: Permission denied
```

**Причина:** Недостаточно прав

**Решение:**
```bash
# Убедитесь что используется root пользователь
# В config/cluster.conf:
SSH_USER="root"

# Или используйте sudo
ssh -i ~/.ssh/id_ed25519 user@node "sudo cp ..."
```

## Проблемы после применения

### kubectl не может подключиться

**Симптомы:**
```
Unable to connect to the server: x509: certificate signed by unknown authority
```

**Причина:** Локальный ~/.kube/config содержит старый CA

**Решение:**
```bash
# Скачать новый kubeconfig с master ноды
scp -i ~/.ssh/id_ed25519 root@192.168.88.191:/etc/kubernetes/admin.conf ~/.kube/config

# ВАЖНО: Проверить server URL в новом kubeconfig
kubectl config view --minify | grep server:

# Должно быть:
# - USE_VIP=true:  server: https://192.168.88.190:6443 (VIP)
# - USE_VIP=false: server: https://192.168.88.191:6443 (MASTER_IP)
```

**Альтернативное решение (обновить только CA):**
```bash
# Получить новый CA в base64
CA_BASE64=$(ssh root@192.168.88.191 "base64 -w 0 /etc/kubernetes/ssl/ca.crt")

# Обновить в ~/.kube/config
kubectl config set clusters.cluster.local.certificate-authority-data $CA_BASE64
```

### Ноды в статусе NotReady

**Симптомы:**
```
NAME      STATUS     ROLES           AGE
master1   NotReady   control-plane   39d
```

**Диагностика:**
```bash
# На проблемной ноде проверить kubelet
ssh root@<node-ip> "systemctl status kubelet"
ssh root@<node-ip> "journalctl -u kubelet -n 50"
```

**Частые причины:**

#### 1. Kubelet получает "Unauthorized"

**Логи:**
```
E1114 13:01:10.085555 1070878 kubelet_node_status.go:107] "Unable to register node with API server" err="Unauthorized"
```

**Причина:** Kubelet клиентский сертификат подписан старым CA

**Решение:**
```bash
ssh root@<node-ip>
systemctl stop kubelet

# Пересоздать kubelet-client-current.pem
cat /var/lib/kubelet/pki/kubelet.crt /var/lib/kubelet/pki/kubelet.key > /var/lib/kubelet/pki/kubelet-client-current.pem
chmod 600 /var/lib/kubelet/pki/kubelet-client-current.pem

systemctl start kubelet

# Проверка
systemctl status kubelet
```

#### 2. CNI проблемы

**Логи:**
```
NetworkReady=false reason:NetworkPluginNotReady message:Network plugin returns error: cni plugin not initialized
```

**Решение:**
Подождите 2-3 минуты для инициализации CNI

### API Server в CrashLoopBackOff

**Симптомы:**
```
kube-apiserver-master2   0/1   CrashLoopBackOff
```

**Диагностика:**
```bash
# Проверить логи API server
ssh root@master2 "crictl logs --tail=50 \$(crictl ps -a | grep kube-apiserver | awk '{print \$1}')"
```

**Причина 1:** Не может подключиться к etcd

**Логи:**
```
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

**Решение:**
```bash
# ВАЖНО: Скрипт apply-all-at-once.sh использует hostname-specific имена
# Каждая нода использует свой сертификат: node-master1.pem, node-master2.pem, node-master3.pem

# Проверить etcd клиентские сертификаты на master2
ssh root@master2 "ls -la /etc/ssl/etcd/ssl/node-master*"

# Если файлов нет или они старые, скопировать новые с правильным именем
scp -i ~/.ssh/id_ed25519 certs/apiserver/apiserver-etcd-client.crt root@master2:/etc/ssl/etcd/ssl/node-master2.pem
scp -i ~/.ssh/id_ed25519 certs/apiserver/apiserver-etcd-client.key root@master2:/etc/ssl/etcd/ssl/node-master2-key.pem

ssh root@master2 "chmod 700 /etc/ssl/etcd/ssl/node-master2*.pem && chown etcd:root /etc/ssl/etcd/ssl/node-master2*.pem"

# Убедиться что манифест API server использует правильный путь
ssh root@master2 "grep 'etcd-certfile' /etc/kubernetes/manifests/kube-apiserver.yaml"
# Должно быть: --etcd-certfile=/etc/ssl/etcd/ssl/node-master2.pem

# Если путь неправильный, обновить манифест
ssh root@master2 "sed -i 's|/etc/ssl/etcd/ssl/node-master1.pem|/etc/ssl/etcd/ssl/node-master2.pem|g' /etc/kubernetes/manifests/kube-apiserver.yaml"
ssh root@master2 "sed -i 's|/etc/ssl/etcd/ssl/node-master1-key.pem|/etc/ssl/etcd/ssl/node-master2-key.pem|g' /etc/kubernetes/manifests/kube-apiserver.yaml"

# Перезапустить API server pod
ssh root@master2 "crictl rm -f \$(crictl ps -a | grep kube-apiserver | awk '{print \$1}')"
```

**Причина 2:** Неправильные Kubernetes сертификаты

**Решение:**
```bash
# Проверить что сертификаты скопированы
ssh root@master2 "ls -la /etc/kubernetes/ssl/"

# Проверить сроки действия
ssh root@master2 "openssl x509 -in /etc/kubernetes/ssl/apiserver.crt -noout -dates"
```

### kube-vip не работает (только для USE_VIP=true)

**Примечание:** Эта проблема актуальна только если в конфигурации `USE_VIP="true"`

**Симптомы:**
```
error retrieving resource lock: Unauthorized
```

**Диагностика:**
```bash
# Проверить что USE_VIP включен
grep USE_VIP config/cluster.conf

# Проверить логи kube-vip
ssh root@master1 "crictl logs --tail=30 \$(crictl ps | grep kube-vip | awk '{print \$1}')"
```

**Причина:** super-admin.conf содержит старый CA или клиентский сертификат

**Решение:**
```bash
# Обновить kubeconfig файлы (если еще не сделано)
./scripts/apply-kubeconfigs.sh

# Перезапустить kube-vip pods
for ip in 192.168.88.191 192.168.88.192 192.168.88.193; do
  ssh root@$ip "crictl rm -f \$(crictl ps | grep kube-vip | awk '{print \$1}')"
done

# Подождать 30 секунд
sleep 30

# Проверить VIP (используйте ваш LB_VIP из конфига)
curl -k https://192.168.88.190:6443/version
```

**Если USE_VIP=false:**
kube-vip не используется, VIP не настроен. Доступ к API Server осуществляется через MASTER_IP.

### Pods в ContainerCreating с ошибкой сертификата

**Симптомы:**
```
calico-kube-controllers   0/1   ContainerCreating
```

**Логи:**
```
Failed to create pod sandbox: plugin type="calico" failed (add): error getting ClusterInformation:
Get "https://10.233.0.1:443/apis/crd.projectcalico.org/v1/clusterinformations/default":
tls: failed to verify certificate: x509: certificate is valid for 192.168.88.191, 192.168.88.190,
192.168.88.191, 192.168.88.192, 192.168.88.193, 127.0.0.1, 10.96.0.1, not 10.233.0.1
```

**Причина 1:** API server сертификат не включает ClusterIP kubernetes service (10.233.0.1)

**Решение:**
```bash
# 1. Проверить реальный ClusterIP kubernetes service
kubectl get svc kubernetes -o yaml | grep clusterIP

# 2. Обновить config/cluster.conf
# Добавить правильный ClusterIP в API_SERVER_SANS (например 10.233.0.1)
# Пример:
# API_SERVER_SANS="kubernetes kubernetes.default ... 10.233.0.1"

# 3. Перегенерировать API server сертификаты
./scripts/generate-apiserver.sh

# Скрипт автоматически добавит:
# - LB_VIP и LB_DNS (если USE_VIP=true)
# - MASTER_IP
# - Все значения из API_SERVER_SANS

# 4. Скопировать на все master ноды
for ip in 192.168.88.191 192.168.88.192 192.168.88.193; do
  scp -i ~/.ssh/id_ed25519 certs/apiserver/apiserver.crt root@$ip:/etc/kubernetes/ssl/apiserver.crt
  scp -i ~/.ssh/id_ed25519 certs/apiserver/apiserver.key root@$ip:/etc/kubernetes/ssl/apiserver.key
  ssh -i ~/.ssh/id_ed25519 root@$ip "crictl rm -f \$(crictl ps -a | grep kube-apiserver | awk '{print \$1}')"
done

# 5. Проверить SAN в новом сертификате
ssh root@192.168.88.191 "openssl x509 -in /etc/kubernetes/ssl/apiserver.crt -noout -text | grep -A2 'Subject Alternative Name'"
```

**Причина 2:** Calico CNI кеширует старый CA certificate

**Решение:**
```bash
# Перезапустить Calico node pods
kubectl delete pod -n kube-system -l k8s-app=calico-node

# Подождать 60 секунд для перезапуска
sleep 60

# Проверить что все pods запустились
kubectl get pods -A
```

## Проблемы с etcd

### etcd не стартует после применения сертификатов

**Симптомы:**
```
Job for etcd.service failed because a timeout was exceeded
```

**Диагностика:**
```bash
ssh root@master1 "journalctl -u etcd -n 100"
```

**Причина 1:** Peer communication failure в multi-master

**Логи:**
```
rejected connection on client endpoint...EOF
remote error: tls: unknown certificate authority
```

**Объяснение:**
В multi-master setup etcd nodes общаются между собой (peer communication).  
Если одна нода имеет новый CA, а другие старый - peer connection fails.

**Решение:**
- **НЕ ОБНОВЛЯЙТЕ НОДЫ ПОСЛЕДОВАТЕЛЬНО**
- Используйте `apply-all-at-once.sh` который:
  1. Останавливает etcd на ВСЕХ нодах
  2. Применяет сертификаты на ВСЕХ нодах
  3. Запускает etcd ОДНОВРЕМЕННО на всех нодах

**Причина 2:** Неправильные права на сертификаты

**Решение:**
```bash
ssh root@master1 "
  chmod 700 /etc/ssl/etcd/ssl/*.pem
  chown -R etcd:root /etc/ssl/etcd/ssl/
"
```

### etcd health check fails

**Симптомы:**
```
https://192.168.88.191:2379 is unhealthy: failed to commit proposal: context deadline exceeded
```

**Диагностика:**
```bash
# Проверить статус etcd
ssh root@master1 "systemctl status etcd"

# Проверить etcd логи
ssh root@master1 "journalctl -u etcd -n 100"

# Попробовать health check с localhost (с master1)
# Для systemd etcd:
ssh root@master1 "
  ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/ssl/etcd/ssl/ca.pem \
    --cert=/etc/ssl/etcd/ssl/admin-master1.pem \
    --key=/etc/ssl/etcd/ssl/admin-master1-key.pem \
    endpoint health
"

# Для static-pod etcd:
ssh root@master1 "
  ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/admin-master1.crt \
    --key=/etc/kubernetes/pki/etcd/admin-master1.key \
    endpoint health
"

# Для проверки с других мастеров используйте соответствующий сертификат:
# systemd:    --cert=/etc/ssl/etcd/ssl/admin-master2.pem --key=/etc/ssl/etcd/ssl/admin-master2-key.pem
# static-pod: --cert=/etc/kubernetes/pki/etcd/admin-master2.crt --key=/etc/kubernetes/pki/etcd/admin-master2.key
```

**Решение:**
Зависит от логов. Обычно проблема в сертификатах или peer communication.

## Проблемы с кластером

### Pods в ContainerCreating долгое время

**Симптомы:**
```
calico-kube-controllers   0/1   ContainerCreating   0   10m
```

**Диагностика:**
```bash
kubectl describe pod calico-kube-controllers-xxx -n kube-system
kubectl get events -n kube-system
```

**Частые причины:**
1. CNI не инициализирован - подождите 2-5 минут
2. Image pull errors - проверьте доступ к registry
3. Volume mount errors - проверьте права на директории

### Control plane компоненты не запускаются

**Проверка:**
```bash
# На master ноде
ssh root@master1 "crictl ps | grep -E 'kube-apiserver|kube-controller|kube-scheduler'"
```

**Решение:**
```bash
# Проверить логи static pods
ssh root@master1 "crictl logs --tail=50 \$(crictl ps -a | grep kube-controller-manager | awk '{print \$1}')"

# Проверить манифесты
ssh root@master1 "ls -la /etc/kubernetes/manifests/"

# Перезапустить kubelet если нужно
ssh root@master1 "systemctl restart kubelet"
```

## Откат изменений

### Быстрый откат одной ноды

```bash
ssh root@<node-ip>
BACKUP_DIR=$(cat /tmp/last-backup-dir)

systemctl stop kubelet
systemctl stop etcd

rm -rf /etc/kubernetes/ssl
cp -r $BACKUP_DIR/kubernetes-ssl /etc/kubernetes/ssl

rm -rf /etc/ssl/etcd
cp -r $BACKUP_DIR/etcd /etc/ssl/

cp $BACKUP_DIR/*.conf /etc/kubernetes/

rm -rf /var/lib/kubelet/pki
cp -r $BACKUP_DIR/kubelet-pki /var/lib/kubelet/pki

systemctl start etcd
sleep 5
systemctl start kubelet
```

### Откат всего кластера

Используйте функцию `rollback_all()` из `apply-all-at-once.sh`:
```bash
# Функция вызывается автоматически при ошибках в скрипте
# Или можно вызвать вручную через редактирование скрипта
```

## Проверка после исправления

```bash
# 1. Проверка нод
kubectl get nodes

# 2. Проверка pods
kubectl get pods -A | grep -v Running

# 3. Проверка etcd (запускать с master1)
# Для systemd etcd (путь: /etc/ssl/etcd/ssl/)
ssh root@192.168.88.191 "
  ETCDCTL_API=3 etcdctl \
    --endpoints=https://192.168.88.191:2379,https://192.168.88.192:2379,https://192.168.88.193:2379 \
    --cacert=/etc/ssl/etcd/ssl/ca.pem \
    --cert=/etc/ssl/etcd/ssl/admin-master1.pem \
    --key=/etc/ssl/etcd/ssl/admin-master1-key.pem \
    endpoint health
"

# Для static-pod etcd (путь: /etc/kubernetes/pki/etcd/)
ssh root@192.168.88.191 "
  ETCDCTL_API=3 etcdctl \
    --endpoints=https://192.168.88.191:2379,https://192.168.88.192:2379,https://192.168.88.193:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/admin-master1.crt \
    --key=/etc/kubernetes/pki/etcd/admin-master1.key \
    endpoint health
"

# 4. Проверка VIP (только если USE_VIP=true)
# Замените 192.168.88.190 на ваш LB_VIP из config/cluster.conf
if grep -q 'USE_VIP="true"' config/cluster.conf; then
  LB_VIP=$(grep '^LB_VIP=' config/cluster.conf | cut -d'"' -f2)
  echo "Проверка VIP: $LB_VIP"
  curl -k https://$LB_VIP:6443/version
else
  echo "USE_VIP=false, пропускаем проверку VIP"
fi

# 5. Проверка сертификатов
for node in 192.168.88.191 192.168.88.192 192.168.88.193; do
  echo "=== $node ==="
  ssh root@$node "openssl x509 -in /etc/kubernetes/ssl/apiserver.crt -noout -dates"
done

# 6. Проверка SAN в сертификате (какие IP/DNS включены)
ssh root@192.168.88.191 "openssl x509 -in /etc/kubernetes/ssl/apiserver.crt -noout -text | grep -A2 'Subject Alternative Name'"
```

## Полезные команды для диагностики

**ВАЖНО:** Каждая master нода использует hostname-specific сертификаты etcd.

**Для systemd etcd (Kubespray):**
- master1: `node-master1.pem`, `member-master1.pem`, `admin-master1.pem`
- master2: `node-master2.pem`, `member-master2.pem`, `admin-master2.pem`
- master3: `node-master3.pem`, `member-master3.pem`, `admin-master3.pem`

**Для static-pod etcd (kubeadm):**
- master1: `node-master1.crt`, `member-master1.crt`, `admin-master1.crt`
- master2: `node-master2.crt`, `member-master2.crt`, `admin-master2.crt`
- master3: `node-master3.crt`, `member-master3.crt`, `admin-master3.crt`

```bash
# Проверка всех сертификатов на ноде (для systemd)
ssh root@<node> "
  for cert in /etc/kubernetes/ssl/*.crt /etc/ssl/etcd/ssl/*.pem; do
    if [[ -f \$cert ]]; then
      echo \"=== \$cert ===\"
      openssl x509 -in \$cert -noout -subject -issuer -dates 2>/dev/null || echo 'Not a valid cert'
    fi
  done
"

# Проверка всех сертификатов на ноде (для static-pod)
ssh root@<node> "
  for cert in /etc/kubernetes/ssl/*.crt /etc/kubernetes/pki/etcd/*.crt; do
    if [[ -f \$cert ]]; then
      echo \"=== \$cert ===\"
      openssl x509 -in \$cert -noout -subject -issuer -dates 2>/dev/null || echo 'Not a valid cert'
    fi
  done
"

# Проверка kubelet
ssh root@<node> "systemctl status kubelet && journalctl -u kubelet -n 20"

# Проверка etcd
ssh root@<node> "systemctl status etcd && journalctl -u etcd -n 20"

# Проверка static pods
ssh root@<node> "crictl ps -a"

# Проверка kubeconfig
ssh root@<node> "kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes"
```

## Получение помощи

Если проблема не решена:

1. Соберите диагностическую информацию:
```bash
# На каждой master ноде
ssh root@<node> "
  journalctl -u kubelet -n 100 > /tmp/kubelet.log
  journalctl -u etcd -n 100 > /tmp/etcd.log 2>/dev/null || echo 'etcd systemd не найден' > /tmp/etcd.log
  crictl ps -a > /tmp/pods.log
  ls -laR /etc/kubernetes/ssl/ > /tmp/k8s-certs.log

  # Для systemd etcd
  ls -laR /etc/ssl/etcd/ssl/ > /tmp/etcd-certs-systemd.log 2>/dev/null || echo 'systemd etcd не найден' > /tmp/etcd-certs-systemd.log

  # Для static-pod etcd
  ls -laR /etc/kubernetes/pki/etcd/ > /tmp/etcd-certs-static.log 2>/dev/null || echo 'static-pod etcd не найден' > /tmp/etcd-certs-static.log

  # Проверить какой тип etcd используется
  if systemctl is-active etcd >/dev/null 2>&1; then
    echo 'systemd' > /tmp/etcd-type.log
  elif [ -f /etc/kubernetes/manifests/etcd.yaml ]; then
    echo 'static-pod' > /tmp/etcd-type.log
  else
    echo 'unknown' > /tmp/etcd-type.log
  fi
"

# Скачать логи
scp root@<node>:/tmp/*.log ./logs/
```

2. Проверьте сертификаты
3. Проверьте права на файлы
4. Проверьте etcd peer communication
5. Проверьте kubeconfig файлы

## Превентивные меры

1. **ВСЕГДА делайте backup перед применением**
2. **Проверьте конфигурацию перед генерацией**:
   ```bash
   # Убедитесь что USE_VIP и ETCD_TYPE установлены правильно
   grep -E 'USE_VIP|LB_VIP|MASTER_IP|ETCD_TYPE' config/cluster.conf

   # Для кластера с VIP (kube-vip, haproxy):
   USE_VIP="true"
   LB_VIP="192.168.88.190"

   # Для кластера без VIP (single master или прямой доступ):
   USE_VIP="false"
   LB_VIP=""

   # Для определения типа etcd (рекомендуется):
   ETCD_TYPE="auto"
   ```
3. **Тестируйте в staging окружении**
4. **Используйте `apply-all-at-once.sh` для multi-master**
5. **Проверяйте сертификаты после генерации**: `./scripts/verify-certs.sh`
6. **Проверяйте SAN в сертификате**:
   ```bash
   openssl x509 -in certs/apiserver/apiserver.crt -noout -text | grep -A2 'Subject Alternative Name'
   # Должны быть включены все необходимые IP и DNS
   ```
7. **Запускайте в maintenance window**
8. **Имейте план отката**

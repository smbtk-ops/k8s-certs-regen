# Troubleshooting Guide

Полное руководство по решению проблем при регенерации сертификатов в multi-master Kubernetes кластерах.

## Содержание

1. [Проблемы при генерации](#проблемы-при-генерации)
2. [Проблемы при применении](#проблемы-при-применении)
3. [Проблемы после применения](#проблемы-после-применения)
4. [Проблемы с etcd](#проблемы-с-etcd)
5. [Проблемы с кластером](#проблемы-с-кластером)

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

**Решение:**
Проверьте что скрипт `generate-kubelet.sh` содержит:
```bash
# Для master нод
for node in $MASTER_NODES; do
    IFS=':' read -r hostname ip <<< "$node"
    generate_kubelet_cert "$hostname" "$ip"
done

# Для worker нод
for node in $WORKER_NODES; do
    IFS=':' read -r hostname ip <<< "$node"
    generate_kubelet_cert "$hostname" "$ip"
done
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
# Скачать новый kubeconfig
scp -i ~/.ssh/id_ed25519 root@192.168.88.191:/etc/kubernetes/admin.conf ~/.kube/config

# Или обновить только CA
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
# Проверить etcd клиентские сертификаты
ssh root@master2 "ls -la /etc/ssl/etcd/ssl/node-master1*"

# Если файлов нет или они старые, скопировать новые
scp -i ~/.ssh/id_ed25519 certs/apiserver/apiserver-etcd-client.crt root@master2:/etc/ssl/etcd/ssl/node-master1.pem
scp -i ~/.ssh/id_ed25519 certs/apiserver/apiserver-etcd-client.key root@master2:/etc/ssl/etcd/ssl/node-master1-key.pem

ssh root@master2 "chmod 700 /etc/ssl/etcd/ssl/node-master1*.pem && chown etcd:root /etc/ssl/etcd/ssl/node-master1*.pem"

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

### kube-vip не работает

**Симптомы:**
```
error retrieving resource lock: Unauthorized
```

**Диагностика:**
```bash
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

# Проверить VIP
curl -k https://192.168.88.190:6443/version
```

### Проблема 7: Pods в ContainerCreating с ошибкой сертификата

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

**Причина 1:** API server сертификат не включает ClusterIP service (10.233.0.1)

**Решение:**
```bash
# Проверить реальный ClusterIP kubernetes service
kubectl get svc kubernetes -o yaml | grep clusterIP

# Обновить config/cluster.conf
# Изменить SERVICE_CIDR и API_SERVER_SANS на правильный IP (например 10.233.0.1)

# Перегенерировать API server сертификаты
./scripts/generate-apiserver.sh

# Скопировать на все master ноды
for ip in 192.168.88.191 192.168.88.192 192.168.88.193; do
  scp -i ~/.ssh/id_ed25519 certs/apiserver/apiserver.crt root@$ip:/etc/kubernetes/ssl/apiserver.crt
  scp -i ~/.ssh/id_ed25519 certs/apiserver/apiserver.key root@$ip:/etc/kubernetes/ssl/apiserver.key
  ssh -i ~/.ssh/id_ed25519 root@$ip "crictl rm -f \$(crictl ps -a | grep kube-apiserver | awk '{print \$1}')"
done
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

# Попробовать health check с localhost
ssh root@master1 "
  ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/ssl/etcd/ssl/ca.pem \
    --cert=/etc/ssl/etcd/ssl/admin-master1.pem \
    --key=/etc/ssl/etcd/ssl/admin-master1-key.pem \
    endpoint health
"
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

# 3. Проверка etcd
ETCDCTL_API=3 etcdctl \
  --endpoints=https://192.168.88.191:2379,https://192.168.88.192:2379,https://192.168.88.193:2379 \
  --cacert=/etc/ssl/etcd/ssl/ca.pem \
  --cert=/etc/ssl/etcd/ssl/admin-master1.pem \
  --key=/etc/ssl/etcd/ssl/admin-master1-key.pem \
  endpoint health

# 4. Проверка VIP
curl -k https://192.168.88.190:6443/version

# 5. Проверка сертификатов
for node in 192.168.88.191 192.168.88.192 192.168.88.193; do
  echo "=== $node ==="
  ssh root@$node "openssl x509 -in /etc/kubernetes/ssl/apiserver.crt -noout -dates"
done
```

## Полезные команды для диагностики

```bash
# Проверка всех сертификатов на ноде
ssh root@<node> "
  for cert in /etc/kubernetes/ssl/*.crt /etc/ssl/etcd/ssl/*.pem; do
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
  journalctl -u etcd -n 100 > /tmp/etcd.log
  crictl ps -a > /tmp/pods.log
  ls -laR /etc/kubernetes/ssl/ > /tmp/k8s-certs.log
  ls -laR /etc/ssl/etcd/ssl/ > /tmp/etcd-certs.log
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
2. **Тестируйте в staging окружении**
3. **Используйте `apply-all-at-once.sh` для multi-master**
4. **Проверяйте сертификаты после генерации**: `./scripts/verify-certs.sh`
5. **Запускайте в maintenance window**
6. **Имейте план отката**

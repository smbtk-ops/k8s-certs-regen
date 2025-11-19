# Ручная регенерация сертификатов Kubernetes через kubeadm

Полное руководство по регенерации сертификатов Kubernetes кластера с использованием встроенного инструмента kubeadm.

## Содержание

1. [Введение](#введение)
2. [Подготовка](#подготовка)
3. [Полная замена сертификатов](#полная-замена-сертификатов)
4. [Модульное обновление](#модульное-обновление)
5. [Проверка и тестирование](#проверка-и-тестирование)
6. [Troubleshooting](#troubleshooting)
7. [Ограничения](#ограничения)

## Введение

### Когда использовать kubeadm метод

kubeadm подходит если:
- Кластер был установлен через kubeadm
- Нужна быстрая регенерация стандартных сертификатов
- Истек срок действия сертификатов и требуется быстрое продление
- Не требуются кастомные параметры (SAN, validity period, etc.)
- etcd работает как static pod (kubeadm по умолчанию)
- Single-master или простой multi-master кластер

### Преимущества kubeadm

- Быстро и просто
- Встроен в Kubernetes
- Автоматически определяет параметры
- Минимум ручной работы
- Официально поддерживается

### Недостатки и ограничения

**ВАЖНЫЕ ОГРАНИЧЕНИЯ:**

1. **Требует kubeadm** - не работает для кластеров установленных другими способами (Kubespray, Ansible, вручную)
2. **Ограниченная поддержка multi-master** - могут быть проблемы с etcd сертификатами
3. **Не поддерживает etcd systemd** - работает только с static-pod etcd
4. **Ограниченная кастомизация SAN** - сложно добавить нестандартные IP/DNS
5. **Не меняет CA** - нельзя заменить корневой CA
6. **Фиксированный срок действия** - обычно 1 год, сложно изменить
7. **Hostname-specific etcd сертификаты** - kubeadm может генерировать их некорректно для некоторых setups

### Требования

**Инструменты:**
- kubeadm (уже установлен если кластер создан через kubeadm)
- kubectl
- SSH доступ ко всем master нодам
- Root права

**Проверка:**
```bash
kubeadm version
# Ожидаемый вывод: kubeadm version: &version.Info{...}

kubectl version --short
```

**Время:**
- Подготовка: 5-10 минут
- Регенерация на одной ноде: 2-5 минут
- Применение на multi-master: 15-30 минут
- Downtime: минимальный (поочередное обновление) или 5-10 минут (одновременное)

## Подготовка

### Шаг 1: Проверка существующих сертификатов

```bash
# На master ноде
sudo kubeadm certs check-expiration

# Пример вывода:
# CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY   EXTERNALLY MANAGED
# admin.conf                 Jan 18, 2026 12:00 UTC   364d            ca                      no
# apiserver                  Jan 18, 2026 12:00 UTC   364d            ca                      no
# apiserver-etcd-client      Jan 18, 2026 12:00 UTC   364d            etcd-ca                 no
# apiserver-kubelet-client   Jan 18, 2026 12:00 UTC   364d            ca                      no
# controller-manager.conf    Jan 18, 2026 12:00 UTC   364d            ca                      no
# etcd-healthcheck-client    Jan 18, 2026 12:00 UTC   364d            etcd-ca                 no
# etcd-peer                  Jan 18, 2026 12:00 UTC   364d            etcd-ca                 no
# etcd-server                Jan 18, 2026 12:00 UTC   364d            etcd-ca                 no
# front-proxy-client         Jan 18, 2026 12:00 UTC   364d            front-proxy-ca          no
# scheduler.conf             Jan 18, 2026 12:00 UTC   364d            ca                      no
#
# CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
# ca                      Jan 16, 2035 11:00 UTC   9y              no
# etcd-ca                 Jan 16, 2035 11:00 UTC   9y              no
# front-proxy-ca          Jan 16, 2035 11:00 UTC   9y              no
```

**Объяснение вывода:**
- `CERTIFICATE` - тип сертификата
- `EXPIRES` - срок истечения
- `RESIDUAL TIME` - оставшееся время
- `CERTIFICATE AUTHORITY` - какой CA подписал
- `EXTERNALLY MANAGED` - управляется ли вне kubeadm

### Шаг 2: Backup

**КРИТИЧЕСКИ ВАЖНО:**

```bash
# На каждой master ноде
for node in master1:192.168.88.191 master2:192.168.88.192 master3:192.168.88.193; do
  IFS=':' read -r hostname ip <<< "$node"
  echo "=== Backup на $hostname ($ip) ==="

  ssh root@$ip "
    BACKUP_DIR=\"/root/k8s-certs-backup-\$(date +%Y%m%d)\"
    mkdir -p \$BACKUP_DIR

    # Backup всех сертификатов
    cp -r /etc/kubernetes/pki \$BACKUP_DIR/pki

    # Backup kubeconfig
    cp /etc/kubernetes/*.conf \$BACKUP_DIR/

    # Backup static pod manifests
    cp -r /etc/kubernetes/manifests \$BACKUP_DIR/manifests

    # Backup kubelet config
    cp -r /var/lib/kubelet/pki \$BACKUP_DIR/kubelet-pki 2>/dev/null || true

    echo \$BACKUP_DIR > /tmp/last-backup-dir
    echo \"Backup: \$BACKUP_DIR\"
  "
done
```

### Шаг 3: Определение типа кластера

```bash
# Проверить как был установлен кластер
"ls /etc/kubernetes/kubeadm-config.yaml"

# Если файл есть - кластер установлен через kubeadm
# Если нет - kubeadm метод НЕ ПОДХОДИТ!

# Проверить etcd тип
"ls /etc/kubernetes/manifests/etcd.yaml"

# Если файл есть - etcd как static pod (поддерживается)
# Если нет - скорее всего etcd systemd (НЕ ПОДДЕРЖИВАЕТСЯ kubeadm)
```

**ВАЖНО:** Если кластер установлен не через kubeadm или etcd работает как systemd - используйте [OpenSSL](openssl.md) или [CFSSL](cfssl.md) методы!

### Шаг 4: Проверка конфигурации API Server

```bash
# Получить текущие SAN
"openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A1 'Subject Alternative Name'"

# Пример вывода:
# X509v3 Subject Alternative Name:
#     DNS:kubernetes, DNS:kubernetes.default, DNS:kubernetes.default.svc, DNS:kubernetes.default.svc.cluster.local, DNS:master1, IP Address:192.168.88.191, IP Address:10.233.0.1
```

Запишите текущие SAN - kubeadm попытается сохранить их, но может не добавить новые.

## Полная замена сертификатов

### Метод 1: Регенерация всех сертификатов (рекомендуется)

**На каждой master ноде ПОСЛЕДОВАТЕЛЬНО:**

```bash
# ВАЖНО: Выполнять на каждой master ноде по очереди!

# Определить master ноду
MASTER_IP="192.168.88.191"  # Замените на текущую ноду

ssh root@$MASTER_IP "
  echo '========================================='
  echo 'Регенерация сертификатов на \$(hostname)'
  echo '========================================='

  # 1. Регенерировать все сертификаты
  kubeadm certs renew all

  # 2. Перезапустить static pods
  # Переместить манифесты и вернуть обратно для перезапуска
  mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
  mv /etc/kubernetes/manifests/kube-controller-manager.yaml /tmp/
  mv /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/
  mv /etc/kubernetes/manifests/etcd.yaml /tmp/

  sleep 10

  mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
  mv /tmp/kube-controller-manager.yaml /etc/kubernetes/manifests/
  mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/
  mv /tmp/etcd.yaml /etc/kubernetes/manifests/

  echo 'Ожидание запуска pods...'
  sleep 30

  # 3. Перезапустить kubelet
  systemctl restart kubelet

  # 4. Обновить admin kubeconfig
  cp /etc/kubernetes/admin.conf /root/.kube/config

  echo '========================================='
  echo 'Готово на \$(hostname)'
  echo '========================================='
"

# Проверка
kubectl --kubeconfig=<(ssh root@$MASTER_IP cat /etc/kubernetes/admin.conf) get nodes

# Повторить для master2 и master3
```

**Пример вывода:**
```
=========================================
Регенерация сертификатов на master1
=========================================
[renew] Reading configuration from the cluster...
[renew] FYI: You can look at this config file with 'kubectl -n kube-system get cm kubeadm-config -o yaml'

certificate embedded in the kubeconfig file for the admin to use and for kubeadm itself renewed
certificate for serving the Kubernetes API renewed
certificate the apiserver uses to access etcd renewed
certificate for the API server to connect to kubelet renewed
certificate embedded in the kubeconfig file for the controller manager to use renewed
certificate for liveness probes to healthcheck etcd renewed
certificate for etcd nodes to communicate with each other renewed
certificate for serving etcd renewed
certificate for the front proxy client renewed
certificate embedded in the kubeconfig file for the scheduler manager to use renewed

Done renewing certificates. You must restart the kube-apiserver, kube-controller-manager, kube-scheduler and etcd, so that they can use the new certificates.
Ожидание запуска pods...
=========================================
Готово на master1
=========================================
```

### Метод 2: Пошаговая регенерация (для продвинутых)

**Регенерация отдельных компонентов:**

```bash
# Только API Server
kubeadm certs renew apiserver

# Только API Server kubelet client
kubeadm certs renew apiserver-kubelet-client

# Только API Server etcd client
kubeadm certs renew apiserver-etcd-client

# Только etcd сертификаты
kubeadm certs renew etcd-healthcheck-client
kubeadm certs renew etcd-peer
kubeadm certs renew etcd-server

# Только Front Proxy
kubeadm certs renew front-proxy-client

# Kubeconfig файлы
kubeadm certs renew admin.conf
kubeadm certs renew controller-manager.conf
kubeadm certs renew scheduler.conf

# Посмотреть доступные команды
kubeadm certs renew --help
```

**После каждого обновления перезапустить соответствующие pods.**

### Метод 3: Одновременное обновление всех master (для опытных)

**ВАЖНО:** Кластер будет недоступен на время обновления!

```bash
#!/bin/bash

MASTER_NODES=(
  "master1:192.168.88.191"
  "master2:192.168.88.192"
  "master3:192.168.88.193"
)

echo "ВНИМАНИЕ: Кластер будет ОСТАНОВЛЕН!"
read -p "Продолжить? (YES): " confirm
[[ "$confirm" != "YES" ]] && exit 1

# 1. Остановить kubelet на всех нодах
echo "[1/6] Остановка kubelet..."
for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r _ ip <<< "$node"
  ssh root@$ip "systemctl stop kubelet" &
done
wait

sleep 5

# 2. Остановить etcd на всех нодах
echo "[2/6] Остановка etcd..."
for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r _ ip <<< "$node"
  ssh root@$ip "mv /etc/kubernetes/manifests/etcd.yaml /tmp/etcd.yaml.backup" &
done
wait

sleep 10

# 3. Регенерировать сертификаты на всех нодах параллельно
echo "[3/6] Регенерация сертификатов..."
for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r hostname ip <<< "$node"
  ssh root@$ip "kubeadm certs renew all" &
done
wait

# 4. Запустить etcd одновременно
echo "[4/6] Запуск etcd..."
for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r _ ip <<< "$node"
  ssh root@$ip "mv /tmp/etcd.yaml.backup /etc/kubernetes/manifests/etcd.yaml" &
done
wait

sleep 15

# 5. Запустить kubelet
echo "[5/6] Запуск kubelet..."
for node in "${MASTER_NODES[@]}"; do
  IFS=':' read -r _ ip <<< "$node"
  ssh root@$ip "systemctl start kubelet" &
done
wait

sleep 30

# 6. Обновить локальный kubeconfig
echo "[6/6] Обновление kubeconfig..."
IFS=':' read -r _ master_ip <<< "${MASTER_NODES[0]}"
scp root@$master_ip:/etc/kubernetes/admin.conf ~/.kube/config

kubectl get nodes

echo "Готово!"
```

## Модульное обновление

### Обновление только API Server

```bash
# На master ноде
kubeadm certs renew apiserver

# Перезапустить API Server pod
mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sleep 5
mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/

# Проверка
sleep 10
kubectl get nodes
```

### Обновление только etcd

```bash
# На master ноде
kubeadm certs renew etcd-server
kubeadm certs renew etcd-peer
kubeadm certs renew etcd-healthcheck-client

# Перезапустить etcd pod
mv /etc/kubernetes/manifests/etcd.yaml /tmp/
sleep 5
mv /tmp/etcd.yaml /etc/kubernetes/manifests/

# Проверка
sleep 15
kubectl get nodes
```

### Обновление admin kubeconfig

```bash
# На master ноде
kubeadm certs renew admin.conf

# Скопировать новый kubeconfig
cp /etc/kubernetes/admin.conf ~/.kube/config

# ИЛИ скачать на локальную машину
scp root@192.168.88.191:/etc/kubernetes/admin.conf ~/.kube/config
```

## Проверка и тестирование

### Проверка 1: Сроки действия

```bash
# После регенерации проверить сроки
kubeadm certs check-expiration

# Ожидаемый вывод: все сертификаты должны иметь новый срок действия
# RESIDUAL TIME должен быть ~364d (1 год)
```

### Проверка 2: Статус кластера

```bash
# Ноды
kubectl get nodes

# Pods
kubectl get pods -A

# Control Plane компоненты
kubectl get pods -n kube-system | grep -E 'apiserver|controller|scheduler|etcd'
```

### Проверка 3: etcd health

```bash
# На master ноде
kubectl -n kube-system exec -it etcd-master1 -- sh -c "
  ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint health
"

# Ожидаемый вывод:
# https://127.0.0.1:2379 is healthy: successfully committed proposal: took = 2.123456ms
```

### Проверка 4: Создание тестового pod

```bash
# Создать
kubectl run test-nginx --image=nginx --restart=Never

# Проверить
kubectl wait --for=condition=Ready pod/test-nginx --timeout=60s
kubectl get pod test-nginx

# Удалить
kubectl delete pod test-nginx
```

## Troubleshooting

### Проблема 1: kubeadm не найден

**Ошибка:**
```
bash: kubeadm: command not found
```

**Причина:** Кластер не установлен через kubeadm.

**Решение:**
Используйте [OpenSSL](openssl.md) или [CFSSL](cfssl.md) методы.

### Проблема 2: Сертификаты не обновляются

**Ошибка:**
```
[renew] Reading configuration from the cluster...
error execution phase check-expiration: couldn't create a kubeadm-certs phase: cluster doesn't use kubeadm
```

**Причина:** Кластер не управляется через kubeadm.

**Решение:**
Используйте [OpenSSL](openssl.md) или [CFSSL](cfssl.md) методы.

### Проблема 3: etcd systemd не поддерживается

**Симптомы:**
```
ls /etc/kubernetes/manifests/etcd.yaml
# ls: cannot access '/etc/kubernetes/manifests/etcd.yaml': No such file or directory

systemctl status etcd
# etcd.service - etcd
#    Loaded: loaded (/etc/systemd/system/etcd.service; enabled; vendor preset: enabled)
#    Active: active (running)
```

**Причина:** etcd работает как systemd service, не как static pod.

**Решение:**
kubeadm НЕ ПОДДЕРЖИВАЕТ etcd systemd!
Используйте [OpenSSL](openssl.md) или [CFSSL](cfssl.md) методы.

### Проблема 4: API Server не запускается после регенерации

**Симптомы:**
```
kubectl get nodes
# The connection to the server 192.168.88.191:6443 was refused
```

**Диагностика:**
```bash
# Проверить статус API Server pod
crictl ps -a | grep kube-apiserver

# Проверить логи
crictl logs <container-id>
```

**Частые причины:**

**4.1. Неправильный SAN**

**Логи:**
```
x509: certificate is valid for ..., not <some-ip>
```

**Решение:**
kubeadm ограничен в кастомизации SAN. Используйте OpenSSL/CFSSL для полного контроля.

**4.2. etcd не запущен**

**Решение:**
```bash
# Проверить etcd pod
crictl ps | grep etcd

# Если нет - проверить манифест
ls /etc/kubernetes/manifests/etcd.yaml

# Запустить
mv /tmp/etcd.yaml.backup /etc/kubernetes/manifests/etcd.yaml
```

### Проблема 5: Мульти-master кластер не работает

**Симптомы:**
После обновления одной ноды, другие ноды не могут подключиться к etcd.

**Причина:**
etcd peer communication использует сертификаты. Если обновить только одну ноду - peer auth fails.

**Решение:**
1. Обновить все master ноды одновременно (Метод 3)
2. ИЛИ использовать OpenSSL/CFSSL для контроля над процессом

### Проблема 6: Kubeconfig не работает

**Симптомы:**
```
Unable to connect to the server: x509: certificate signed by unknown authority
```

**Решение:**
```bash
# Обновить admin.conf
kubeadm certs renew admin.conf

# Скопировать новый kubeconfig
cp /etc/kubernetes/admin.conf ~/.kube/config
```

## Ограничения

### Ограничение 1: Срок действия фиксирован

kubeadm генерирует сертификаты на **1 год** (365 дней).

**Обход:**
```bash
# НЕТ простого способа изменить через kubeadm!

# Вариант 1: Регенерировать вручную через OpenSSL/CFSSL

# Вариант 2: Изменить код kubeadm и пересобрать (НЕ РЕКОМЕНДУЕТСЯ)

# Вариант 3: Настроить автоматическую ротацию (рекомендуется)
# Используйте cert-manager или cron job для регулярной регенерации
```

### Ограничение 2: Кастомизация SAN

kubeadm автоматически определяет SAN, но не позволяет легко добавлять кастомные.

**Обход:**
```bash
# Отредактировать kubeadm-config (сложно и может не сработать)

# ИЛИ использовать OpenSSL/CFSSL для полного контроля
```

### Ограничение 3: Не меняет CA

```bash
kubeadm certs renew all

# Обновляет только leaf сертификаты!
# CA остается прежним
```

**Если нужно заменить CA:**
Используйте [OpenSSL](openssl.md) или [CFSSL](cfssl.md) методы.

### Ограничение 4: Только для kubeadm кластеров

**Не работает для:**
- Kubespray установок
- Ansible установок
- Ручных установок
- Managed Kubernetes (EKS, GKE, AKS)

**Решение:**
Используйте [OpenSSL](openssl.md) или [CFSSL](cfssl.md) методы.

### Ограничение 5: etcd systemd не поддерживается

kubeadm работает только с etcd static pod.

**Если у вас etcd systemd (Kubespray):**
Используйте [OpenSSL](openssl.md) или [CFSSL](cfssl.md) методы.

## Автоматизация регенерации

### Cron job для автоматической ротации

```bash
# Создать скрипт
cat > /usr/local/bin/k8s-renew-certs.sh <<'EOF'
#!/bin/bash

LOG_FILE="/var/log/k8s-cert-renew.log"

echo "$(date): Starting certificate renewal" >> $LOG_FILE

# Регенерировать
kubeadm certs renew all >> $LOG_FILE 2>&1

# Перезапустить static pods
kubectl -n kube-system delete pod -l component=kube-apiserver >> $LOG_FILE 2>&1
kubectl -n kube-system delete pod -l component=kube-controller-manager >> $LOG_FILE 2>&1
kubectl -n kube-system delete pod -l component=kube-scheduler >> $LOG_FILE 2>&1
kubectl -n kube-system delete pod -l component=etcd >> $LOG_FILE 2>&1

# Перезапустить kubelet
systemctl restart kubelet >> $LOG_FILE 2>&1

echo "$(date): Certificate renewal completed" >> $LOG_FILE
EOF

chmod +x /usr/local/bin/k8s-renew-certs.sh

# Добавить в cron (каждый месяц)
echo "0 2 1 * * /usr/local/bin/k8s-renew-certs.sh" | crontab -
```

**ВАЖНО:** Это простой пример. Для production используйте cert-manager или Vault.

## Заключение

kubeadm метод - самый быстрый для простых сценариев, но с существенными ограничениями.

**Преимущества:**
- Быстро (одна команда)
- Просто
- Официально поддерживается

**Недостатки:**
- Только для kubeadm кластеров
- Только etcd static-pod
- Ограниченная кастомизация
- Фиксированный срок действия (1 год)
- Не меняет CA

**Рекомендации:**

**Используйте kubeadm если:**
- Кластер установлен через kubeadm
- Нужно быстро продлить срок действия
- Нет специфичных требований

**Используйте OpenSSL/CFSSL если:**
- Кластер НЕ установлен через kubeadm
- etcd работает как systemd
- Нужны кастомные SAN
- Нужен длительный срок действия (>1 год)
- Нужно заменить CA
- Требуется полный контроль

**Дальнейшее чтение:**
- [kubeadm certs документация](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/)
- [OpenSSL метод](openssl.md)
- [CFSSL метод](cfssl.md)
- [Сравнение методов](README.md)
- [cert-manager для автоматической ротации](https://cert-manager.io/)

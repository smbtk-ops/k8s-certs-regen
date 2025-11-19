# Ручная регенерация сертификатов Kubernetes через kubeadm

Пошаговое руководство по ручному перевыпуску сертификатов Kubernetes кластера с использованием встроенного инструмента kubeadm. Описаны действия руками на каждой ноде.

## Содержание

1. [Введение](#введение)
2. [Подготовка](#подготовка)
3. [Создание резервных копий](#создание-резервных-копий)
4. [Регенерация сертификатов](#регенерация-сертификатов)
5. [Проверка и тестирование](#проверка-и-тестирование)
6. [Troubleshooting](#troubleshooting)
7. [Ограничения](#ограничения)

## Введение

Это руководство описывает **ручной** процесс перевыпуска сертификатов Kubernetes через kubeadm. Вы будете заходить на каждую ноду и выполнять команды последовательно.

### Когда использовать kubeadm метод

kubeadm подходит если:
- Кластер был установлен через kubeadm
- Нужна быстрая регенерация стандартных сертификатов
- Истек срок действия сертификатов
- etcd работает как static pod (kubeadm по умолчанию)

### ВАЖНЫЕ ОГРАНИЧЕНИЯ

1. **Требует kubeadm** - не работает для кластеров установленных через Kubespray, Ansible или вручную
2. **Не поддерживает etcd systemd** - работает только с static-pod etcd
3. **Ограниченная кастомизация SAN** - сложно добавить нестандартные IP/DNS
4. **Не меняет CA** - нельзя заменить корневой CA
5. **Фиксированный срок действия** - обычно 1 год

### Информация о кластере

**Используемая конфигурация:**
- Master ноды: master1 (192.168.88.191), master2 (192.168.88.192), master3 (192.168.88.193)
- Worker ноды: worker1 (192.168.88.194), worker2 (192.168.88.195)
- HA VIP: 192.168.88.190

### Требования

**Необходимо:**
- Кластер установлен через kubeadm
- SSH доступ ко всем master нодам
- Root права на всех нодах
- kubeadm уже установлен

**Время выполнения:**
- Подготовка: 5-10 минут
- Регенерация на одной ноде: 2-5 минут
- Полное обновление кластера: 15-30 минут
- Downtime: минимальный (последовательное обновление)

## Подготовка

### Шаг 1: Проверка что кластер установлен через kubeadm

Зайдите на первую master ноду:

```bash
ssh root@192.168.88.191
```

Проверьте наличие конфига kubeadm:

```bash
ls -lh /etc/kubernetes/kubeadm-config.yaml
```

Если файл существует - кластер установлен через kubeadm и можно продолжать.

Проверьте что etcd работает как static pod:

```bash
ls -lh /etc/kubernetes/manifests/etcd.yaml
```

Если файл существует - etcd static pod, kubeadm поддерживается.

Если файла нет:

```bash
systemctl status etcd
```

Если etcd работает как systemd service - kubeadm НЕ ПОДХОДИТ! Используйте OpenSSL или CFSSL методы.

### Шаг 2: Проверка текущих сертификатов

На ноде master1:

```bash
kubeadm certs check-expiration
```

Вы увидите список всех сертификатов с датами истечения:

```
CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY
admin.conf                 Jan 18, 2026 12:00 UTC   364d            ca
apiserver                  Jan 18, 2026 12:00 UTC   364d            ca
apiserver-etcd-client      Jan 18, 2026 12:00 UTC   364d            etcd-ca
apiserver-kubelet-client   Jan 18, 2026 12:00 UTC   364d            ca
controller-manager.conf    Jan 18, 2026 12:00 UTC   364d            ca
etcd-healthcheck-client    Jan 18, 2026 12:00 UTC   364d            etcd-ca
etcd-peer                  Jan 18, 2026 12:00 UTC   364d            etcd-ca
etcd-server                Jan 18, 2026 12:00 UTC   364d            etcd-ca
front-proxy-client         Jan 18, 2026 12:00 UTC   364d            front-proxy-ca
scheduler.conf             Jan 18, 2026 12:00 UTC   364d            ca
```

Проверьте текущие SAN для API Server:

```bash
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A1 "Subject Alternative Name"
```

Запишите текущие SAN - kubeadm постарается их сохранить.

Выйдите с ноды:

```bash
exit
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
echo "Создана директория: $BACKUP_DIR"
```

Скопируйте все сертификаты:

```bash
cp -r /etc/kubernetes/pki $BACKUP_DIR/pki
```

Скопируйте kubeconfig файлы:

```bash
cp /etc/kubernetes/admin.conf $BACKUP_DIR/
cp /etc/kubernetes/controller-manager.conf $BACKUP_DIR/
cp /etc/kubernetes/scheduler.conf $BACKUP_DIR/
cp /etc/kubernetes/kubelet.conf $BACKUP_DIR/
```

Скопируйте манифесты static pods:

```bash
cp -r /etc/kubernetes/manifests $BACKUP_DIR/manifests
```

Скопируйте kubelet сертификаты:

```bash
cp -r /var/lib/kubelet/pki $BACKUP_DIR/kubelet-pki 2>/dev/null || true
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

Повторите те же действия на master2:

```bash
ssh root@192.168.88.192
BACKUP_DIR="/root/k8s-certs-backup-$(date +%Y%m%d_%H%M%S)"
mkdir -p $BACKUP_DIR
echo "Создана директория: $BACKUP_DIR"
cp -r /etc/kubernetes/pki $BACKUP_DIR/pki
cp /etc/kubernetes/admin.conf $BACKUP_DIR/
cp /etc/kubernetes/controller-manager.conf $BACKUP_DIR/
cp /etc/kubernetes/scheduler.conf $BACKUP_DIR/
cp /etc/kubernetes/kubelet.conf $BACKUP_DIR/
cp -r /etc/kubernetes/manifests $BACKUP_DIR/manifests
cp -r /var/lib/kubelet/pki $BACKUP_DIR/kubelet-pki 2>/dev/null || true
ls -lah $BACKUP_DIR/
echo "Бэкап сохранен в: $BACKUP_DIR"
exit
```

### Шаг 5: Создание бэкапа на master3

```bash
ssh root@192.168.88.193
BACKUP_DIR="/root/k8s-certs-backup-$(date +%Y%m%d_%H%M%S)"
mkdir -p $BACKUP_DIR
echo "Создана директория: $BACKUP_DIR"
cp -r /etc/kubernetes/pki $BACKUP_DIR/pki
cp /etc/kubernetes/admin.conf $BACKUP_DIR/
cp /etc/kubernetes/controller-manager.conf $BACKUP_DIR/
cp /etc/kubernetes/scheduler.conf $BACKUP_DIR/
cp /etc/kubernetes/kubelet.conf $BACKUP_DIR/
cp -r /etc/kubernetes/manifests $BACKUP_DIR/manifests
cp -r /var/lib/kubelet/pki $BACKUP_DIR/kubelet-pki 2>/dev/null || true
ls -lah $BACKUP_DIR/
echo "Бэкап сохранен в: $BACKUP_DIR"
exit
```

## Регенерация сертификатов

### Важное замечание о последовательности

Вы можете обновлять master ноды **последовательно** (с минимальным downtime) или **одновременно** (быстрее, но кластер будет недоступен).

Ниже описан **последовательный** метод (рекомендуется).

### Шаг 6: Регенерация на master1

Зайдите на master1:

```bash
ssh root@192.168.88.191
```

Регенерируйте все сертификаты:

```bash
kubeadm certs renew all
```

Вы увидите вывод:

```
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
```

Перезапустите static pods. Переместите манифесты во временную директорию:

```bash
mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
mv /etc/kubernetes/manifests/kube-controller-manager.yaml /tmp/
mv /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/
mv /etc/kubernetes/manifests/etcd.yaml /tmp/
```

Подождите 10 секунд чтобы pods остановились:

```bash
sleep 10
```

Верните манифесты обратно:

```bash
mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
mv /tmp/kube-controller-manager.yaml /etc/kubernetes/manifests/
mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/
mv /tmp/etcd.yaml /etc/kubernetes/manifests/
```

Подождите запуска pods:

```bash
echo "Ожидание запуска pods..."
sleep 30
```

Перезапустите kubelet:

```bash
systemctl restart kubelet
```

Обновите admin kubeconfig:

```bash
cp /etc/kubernetes/admin.conf /root/.kube/config
```

Проверьте статус:

```bash
kubectl get nodes
kubectl get pods -n kube-system | grep -E 'apiserver|controller|scheduler|etcd'
```

Если все работает - выйдите:

```bash
exit
```

### Шаг 7: Регенерация на master2

Зайдите на master2:

```bash
ssh root@192.168.88.192
```

Регенерируйте сертификаты:

```bash
kubeadm certs renew all
```

Перезапустите static pods:

```bash
mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
mv /etc/kubernetes/manifests/kube-controller-manager.yaml /tmp/
mv /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/
mv /etc/kubernetes/manifests/etcd.yaml /tmp/
sleep 10
mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
mv /tmp/kube-controller-manager.yaml /etc/kubernetes/manifests/
mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/
mv /tmp/etcd.yaml /etc/kubernetes/manifests/
echo "Ожидание запуска pods..."
sleep 30
```

Перезапустите kubelet:

```bash
systemctl restart kubelet
```

Обновите kubeconfig:

```bash
cp /etc/kubernetes/admin.conf /root/.kube/config
```

Проверьте:

```bash
kubectl get nodes
kubectl get pods -n kube-system | grep -E 'apiserver|controller|scheduler|etcd'
```

Выйдите:

```bash
exit
```

### Шаг 8: Регенерация на master3

Зайдите на master3:

```bash
ssh root@192.168.88.193
```

Регенерируйте сертификаты:

```bash
kubeadm certs renew all
```

Перезапустите static pods:

```bash
mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
mv /etc/kubernetes/manifests/kube-controller-manager.yaml /tmp/
mv /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/
mv /etc/kubernetes/manifests/etcd.yaml /tmp/
sleep 10
mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
mv /tmp/kube-controller-manager.yaml /etc/kubernetes/manifests/
mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/
mv /tmp/etcd.yaml /etc/kubernetes/manifests/
echo "Ожидание запуска pods..."
sleep 30
```

Перезапустите kubelet:

```bash
systemctl restart kubelet
```

Обновите kubeconfig:

```bash
cp /etc/kubernetes/admin.conf /root/.kube/config
```

Проверьте:

```bash
kubectl get nodes
kubectl get pods -n kube-system | grep -E 'apiserver|controller|scheduler|etcd'
```

Выйдите:

```bash
exit
```

### Шаг 9: Обновление локального kubeconfig

На вашей локальной машине обновите kubeconfig:

```bash
scp root@192.168.88.191:/etc/kubernetes/admin.conf ~/.kube/config
```

Проверьте доступ:

```bash
kubectl get nodes
kubectl get pods -A
```

## Проверка и тестирование

### Шаг 10: Проверка сроков действия сертификатов

Зайдите на любую master ноду:

```bash
ssh root@192.168.88.191
```

Проверьте сроки:

```bash
kubeadm certs check-expiration
```

Все сертификаты должны показывать RESIDUAL TIME около 364d (1 год).

Выйдите:

```bash
exit
```

### Шаг 11: Проверка etcd health

Зайдите на master1:

```bash
ssh root@192.168.88.191
```

Проверьте etcd:

```bash
kubectl -n kube-system exec -it etcd-master1 -- sh -c "
  ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint health
"
```

Ожидаемый вывод:

```
https://127.0.0.1:2379 is healthy: successfully committed proposal: took = 2.123456ms
```

Выйдите:

```bash
exit
```

### Шаг 12: Проверка работы кластера

На локальной машине проверьте ноды:

```bash
kubectl get nodes
```

Все ноды должны быть в статусе Ready.

Проверьте pods:

```bash
kubectl get pods -A
```

Создайте тестовый pod:

```bash
kubectl run test-nginx --image=nginx --restart=Never
```

Подождите пока pod запустится:

```bash
kubectl wait --for=condition=Ready pod/test-nginx --timeout=60s
```

Проверьте статус:

```bash
kubectl get pod test-nginx
```

Удалите тестовый pod:

```bash
kubectl delete pod test-nginx
```

## Troubleshooting

### Проблема 1: kubeadm не найден

Зайдите на master ноду:

```bash
ssh root@192.168.88.191
which kubeadm
```

Если команда не найдена:

```
bash: kubeadm: command not found
```

Это значит что кластер не установлен через kubeadm. Используйте OpenSSL или CFSSL методы.

### Проблема 2: etcd работает как systemd

Проверьте:

```bash
ssh root@192.168.88.191
ls /etc/kubernetes/manifests/etcd.yaml
```

Если файла нет:

```
ls: cannot access '/etc/kubernetes/manifests/etcd.yaml': No such file or directory
```

Проверьте systemd:

```bash
systemctl status etcd
```

Если etcd запущен как systemd service - kubeadm НЕ ПОДДЕРЖИВАЕТ это! Используйте OpenSSL или CFSSL методы.

### Проблема 3: API Server не запускается

Зайдите на проблемную ноду:

```bash
ssh root@192.168.88.191
```

Проверьте статус контейнеров:

```bash
crictl ps -a | grep kube-apiserver
```

Проверьте логи:

```bash
crictl logs <container-id>
```

Если видите ошибку про сертификаты:

```
x509: certificate is valid for ..., not <some-ip>
```

Это означает проблему с SAN. kubeadm ограничен в кастомизации SAN. Используйте OpenSSL/CFSSL для полного контроля.

### Проблема 4: Kubeconfig не работает

На локальной машине если видите ошибку:

```
Unable to connect to the server: x509: certificate signed by unknown authority
```

Обновите kubeconfig:

```bash
scp root@192.168.88.191:/etc/kubernetes/admin.conf ~/.kube/config
```

### Проблема 5: etcd peer communication failed

Если после обновления одной master ноды другие не могут подключиться к etcd, это означает проблемы с peer сертификатами.

Решение: обновите все master ноды последовательно как описано выше.

## Ограничения

### 1. Срок действия фиксирован на 1 год

kubeadm генерирует сертификаты только на 1 год (365 дней). Нет простого способа это изменить.

Если нужен больший срок - используйте OpenSSL или CFSSL методы.

### 2. Ограниченная кастомизация SAN

kubeadm автоматически определяет SAN, но сложно добавить кастомные IP/DNS.

Для полного контроля - используйте OpenSSL или CFSSL методы.

### 3. Не меняет CA

```bash
kubeadm certs renew all
```

Эта команда обновляет только leaf сертификаты. CA остается прежним.

Если нужно заменить CA - используйте OpenSSL или CFSSL методы.

### 4. Только для kubeadm кластеров

kubeadm НЕ РАБОТАЕТ для:
- Кластеров установленных через Kubespray
- Кластеров установленных через Ansible
- Кластеров установленных вручную
- Managed Kubernetes (EKS, GKE, AKS)

### 5. Только etcd static pod

kubeadm работает только с etcd static pod. Если etcd работает как systemd service (типично для Kubespray) - используйте OpenSSL или CFSSL методы.

## Частичное обновление сертификатов

Если нужно обновить только определенные сертификаты, можно использовать отдельные команды.

### Обновление только API Server

Зайдите на master ноду:

```bash
ssh root@192.168.88.191
```

Обновите сертификат API Server:

```bash
kubeadm certs renew apiserver
```

Перезапустите API Server pod:

```bash
mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sleep 5
mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
sleep 10
```

Проверьте:

```bash
kubectl get nodes
```

### Обновление только etcd сертификатов

```bash
kubeadm certs renew etcd-server
kubeadm certs renew etcd-peer
kubeadm certs renew etcd-healthcheck-client
```

Перезапустите etcd:

```bash
mv /etc/kubernetes/manifests/etcd.yaml /tmp/
sleep 5
mv /tmp/etcd.yaml /etc/kubernetes/manifests/
sleep 15
```

### Обновление только admin kubeconfig

```bash
kubeadm certs renew admin.conf
```

Скопируйте новый kubeconfig:

```bash
cp /etc/kubernetes/admin.conf ~/.kube/config
```

Или скачайте на локальную машину:

```bash
exit  # выйти с master ноды
scp root@192.168.88.191:/etc/kubernetes/admin.conf ~/.kube/config
```

### Список доступных команд

Посмотреть все доступные опции:

```bash
ssh root@192.168.88.191
kubeadm certs renew --help
```

Вывод:

```
Available Commands:
  all                      Renew all certificates
  admin.conf               Renew the admin.conf certificate
  apiserver                Renew the API server certificate
  apiserver-etcd-client    Renew the etcd client certificate for the API server
  apiserver-kubelet-client Renew the kubelet client certificate for the API server
  controller-manager.conf  Renew the controller-manager.conf certificate
  etcd-healthcheck-client  Renew the healthcheck client certificate for etcd
  etcd-peer                Renew the peer certificate for etcd
  etcd-server              Renew the server certificate for etcd
  front-proxy-client       Renew the front-proxy client certificate
  scheduler.conf           Renew the scheduler.conf certificate
```

## Заключение

kubeadm метод - самый простой и быстрый для регенерации сертификатов, но работает только для кластеров установленных через kubeadm и имеет ограничения.

**Используйте kubeadm если:**
- Кластер установлен через kubeadm
- etcd работает как static pod
- Нужно быстро продлить срок действия сертификатов
- Нет специфичных требований к SAN или сроку действия

**Используйте OpenSSL или CFSSL если:**
- Кластер НЕ установлен через kubeadm (Kubespray, Ansible, вручную)
- etcd работает как systemd service
- Нужны кастомные SAN
- Нужен срок действия больше 1 года
- Нужно заменить CA
- Требуется полный контроль над процессом

**Дополнительные материалы:**
- [OpenSSL метод](openssl.md) - полный ручной контроль
- [CFSSL метод](cfssl.md) - альтернативный подход
- [Сравнение методов](README.md)
- [kubeadm certs документация](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/)

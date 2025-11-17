# Типы сертификатов в Kubernetes

Документ описывает все типы сертификатов, используемые в кластере Kubernetes.

## 1. CA Сертификаты (Certificate Authority)

### Kubernetes CA
- **Файлы**: `ca.crt`, `ca.key`
- **Назначение**: Корневой центр сертификации для всех компонентов кластера
- **Подписывает**: API Server, Controller Manager, Scheduler, Admin, Proxy, Kubelet

### etcd CA
- **Файлы**: `etcd/ca.crt`, `etcd/ca.key`
- **Назначение**: Центр сертификации для etcd кластера
- **Подписывает**: etcd Server, etcd Peer, etcd Client сертификаты

### Front Proxy CA
- **Файлы**: `front-proxy-ca.crt`, `front-proxy-ca.key`
- **Назначение**: Центр сертификации для front proxy
- **Подписывает**: Front Proxy Client сертификаты

## 2. API Server Сертификаты

### API Server Server Certificate
- **Файлы**: `apiserver.crt`, `apiserver.key`
- **CN**: `kube-apiserver`
- **SAN**: IP адреса и DNS имена API Server
- **Назначение**: Аутентификация API Server при входящих соединениях

### API Server Kubelet Client
- **Файлы**: `apiserver-kubelet-client.crt`, `apiserver-kubelet-client.key`
- **CN**: `kube-apiserver-kubelet-client`
- **O**: `system:masters`
- **Назначение**: Аутентификация API Server при подключении к kubelet

### API Server etcd Client
- **Файлы**: `apiserver-etcd-client.crt`, `apiserver-etcd-client.key`
- **CN**: `kube-apiserver-etcd-client`
- **O**: `system:masters`
- **Назначение**: Аутентификация API Server при подключении к etcd

## 3. etcd Сертификаты

### etcd Server Certificate
- **Файлы**: `etcd/server.crt`, `etcd/server.key`
- **CN**: hostname мастера
- **SAN**: IP адреса и hostname всех etcd узлов
- **Назначение**: Аутентификация etcd server

### etcd Peer Certificate
- **Файлы**: `etcd/peer.crt`, `etcd/peer.key`
- **CN**: hostname мастера
- **SAN**: IP адреса и hostname всех etcd узлов
- **Назначение**: Peer-to-peer коммуникация между узлами etcd

### etcd Healthcheck Client
- **Файлы**: `etcd/healthcheck-client.crt`, `etcd/healthcheck-client.key`
- **CN**: `kube-etcd-healthcheck-client`
- **O**: `system:masters`
- **Назначение**: Проверка здоровья etcd

## 4. Controller Manager Сертификаты

### Controller Manager Client
- **Файлы**: `controller-manager.crt`, `controller-manager.key`
- **CN**: `system:kube-controller-manager`
- **O**: `system:kube-controller-manager`
- **Назначение**: Аутентификация Controller Manager при подключении к API Server

## 5. Scheduler Сертификаты

### Scheduler Client
- **Файлы**: `scheduler.crt`, `scheduler.key`
- **CN**: `system:kube-scheduler`
- **O**: `system:kube-scheduler`
- **Назначение**: Аутентификация Scheduler при подключении к API Server

## 6. Admin Сертификаты

### Admin Client
- **Файлы**: `admin.crt`, `admin.key`
- **CN**: `kubernetes-admin`
- **O**: `system:masters`
- **Назначение**: Административный доступ к кластеру

## 7. Kube Proxy Сертификаты

### Kube Proxy Client
- **Файлы**: `kube-proxy.crt`, `kube-proxy.key`
- **CN**: `system:kube-proxy`
- **O**: `system:node-proxier`
- **Назначение**: Аутентификация Kube Proxy при подключении к API Server

## 8. Kubelet Сертификаты

### Kubelet Server/Client
- **Файлы**: `kubelet.crt`, `kubelet.key` (для каждой ноды)
- **CN**: `system:node:<hostname>`
- **O**: `system:nodes`
- **SAN**: hostname и IP адрес ноды
- **Назначение**: Аутентификация kubelet

## 9. Service Account Keys

### Service Account Key Pair
- **Файлы**: `sa.key`, `sa.pub`
- **Назначение**: Подпись и проверка Service Account токенов

## 10. Front Proxy Сертификаты

### Front Proxy Client
- **Файлы**: `front-proxy-client.crt`, `front-proxy-client.key`
- **CN**: `front-proxy-client`
- **Назначение**: Расширение API через aggregation layer

## Важные замечания

1. Все сертификаты должны быть подписаны соответствующим CA
2. SAN (Subject Alternative Names) критически важны для API Server
3. Organization (O) определяет группу пользователя в RBAC
4. CommonName (CN) определяет имя пользователя в RBAC
5. Срок действия сертификатов по умолчанию - 1 год (в kubeadm)

# GĐ3 – Phần 1: Deploy app lên K8s bằng manifest thuần (Kustomize)

**Mục tiêu:** chạy toàn bộ Retail Store trên cluster RKE2, truy cập qua Ingress, dữ liệu DB nằm trên Longhorn.

**GĐ3 gồm 3 phần:**
| Phần | Nội dung |
|---|---|
| **1 (file này)** | Đẩy image lên registry, viết manifest: StatefulSet, Deployment, Service, ConfigMap, Secret, probe, resources, securityContext, Ingress |
| 2 | Đóng gói thành Helm chart |
| 3 | HPA, PDB, NetworkPolicy, CronJob backup DB lên S3 |

> Viết tay manifest trước rồi mới học Helm: hiểu từng object K8s thì sau này đọc và debug chart mới dễ.

---

## Bước 0 – Dựng lại cluster

```bash
curl -s https://checkip.amazonaws.com        # IP đổi thì sửa terraform.tfvars
terraform -chdir=infra/terraform/main apply
cd infra/ansible && ansible-playbook site.yml && cd -
kubectl get nodes                            # 3 node Ready
```
✅ Lần dựng này cũng là bài kiểm tra "dựng lại từ đầu" còn thiếu của GĐ2.

Kiểm tra Ingress Controller của RKE2 (bản v1.36 dùng **Traefik**):
```bash
kubectl get ingressclass                                   # kỳ vọng: traefik
kubectl -n kube-system get ds,deploy,svc | grep -i traefik
```
Ghi lại cách Traefik được expose, vì ở Bước 5 sẽ dùng:
- Có **DaemonSet** với `hostPort` 80/443: truy cập được bằng `http://<IP node>/`. Đây là trường hợp phổ biến với RKE2.
- Chỉ có **Service `LoadBalancer`** ở trạng thái `<pending>`: xem mục Lỗi hay gặp ở cuối file.

---

## Bước 1 – Đẩy image lên registry (GHCR)

Cluster không đọc được image trên laptop của bạn, nên phải đẩy image lên một registry. Chọn **GitHub Container Registry (GHCR)** vì repo đã nằm trên GitHub và GHCR miễn phí.

### 1.1 Build nhanh hơn cho amd64
Mac của bạn dùng chip `arm64`, còn EC2 là `amd64`. Nếu build thẳng, Docker phải **giả lập amd64 bằng QEMU**, và riêng bước Maven có thể mất 10–20 phút cho mỗi service.

Cách xử lý: cho **stage build chạy bằng kiến trúc gốc của máy** (`$BUILDPLATFORM`), chỉ stage runtime dùng kiến trúc đích. File `.jar` (Java) và binary Go build bằng `GOARCH` không phụ thuộc kiến trúc máy build, nên làm vậy an toàn.

Sửa dòng `FROM` của **stage build** trong 4 file sau:
```dockerfile
# src/cart/Dockerfile, src/orders/Dockerfile, src/ui/Dockerfile
FROM --platform=$BUILDPLATFORM maven:3.9-eclipse-temurin-21 AS build

# src/catalog/Dockerfile (đã có sẵn TARGETOS/TARGETARCH để cross-compile)
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS build
```
`checkout` (Node) giữ nguyên. Thư viện npm có thể chứa native module, nên phải build đúng kiến trúc đích (vẫn chạy qua QEMU, nhưng Node build nhanh).

### 1.2 Đăng nhập GHCR
1. GitHub → Settings → Developer settings → Personal access tokens (classic) → tạo token có scope **`write:packages`**.
2. Đăng nhập:
```bash
export CR_PAT=<token>
echo $CR_PAT | docker login ghcr.io -u dwchwang --password-stdin
```

### 1.3 Build và push
```bash
TAG=0.1.0
for s in catalog cart orders checkout ui; do
  docker buildx build --platform linux/amd64 \
    -t ghcr.io/dwchwang/retail-store-$s:$TAG \
    --push src/$s
done
```
- **Tag theo version (`0.1.0`), không dùng `latest`.** Nhìn tag là biết chính xác đang chạy bản nào, và rollback chỉ cần đổi tag. Ở GĐ4, CI sẽ tag bằng git SHA.
- Image mới đẩy lên GHCR mặc định ở chế độ **private**. Vào GitHub → Packages → từng package → *Package settings* → **Change visibility → Public**.
  *(Ở công ty, image để private và cluster dùng `imagePullSecret`. Phần 3 sẽ làm cách này.)*

Kiểm tra: `docker manifest inspect ghcr.io/dwchwang/retail-store-catalog:0.1.0 | grep architecture` phải ra `amd64`.

---

## Bước 2 – Cấu trúc thư mục và Kustomize

**Kustomize** có sẵn trong `kubectl` (`kubectl apply -k`), không cần cài thêm. Nó giúp:
- Apply cả thư mục bằng một lệnh.
- **Sinh Secret từ file `.env` không commit** (`secretGenerator`).
- Đổi tag image ở một chỗ duy nhất (`images:`).

```
k8s/
├── kustomization.yaml
├── namespace.yaml
├── ingress.yaml
├── secrets/
│   ├── catalog-db.env          # KHÔNG commit
│   ├── orders-db.env           # KHÔNG commit
│   ├── rabbitmq.env            # KHÔNG commit
│   └── *.env.example           # commit
├── data/
│   ├── catalog-db.yaml         # MariaDB    – StatefulSet
│   ├── orders-db.yaml          # PostgreSQL – StatefulSet
│   ├── rabbitmq.yaml           # RabbitMQ   – StatefulSet
│   ├── cart-db.yaml            # DynamoDB Local – StatefulSet
│   └── checkout-redis.yaml     # Redis      – Deployment (không cần lưu)
└── apps/
    ├── catalog.yaml
    ├── cart.yaml
    ├── orders.yaml
    ├── checkout.yaml
    └── ui.yaml
```
```bash
mkdir -p k8s/{secrets,data,apps}
# .gitignore đã có sẵn dòng k8s/secrets/*.env
```

**`k8s/kustomization.yaml`**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: retail-store

resources:
  - namespace.yaml
  - data/catalog-db.yaml
  - data/orders-db.yaml
  - data/rabbitmq.yaml
  - data/cart-db.yaml
  - data/checkout-redis.yaml
  - apps/catalog.yaml
  - apps/cart.yaml
  - apps/orders.yaml
  - apps/checkout.yaml
  - apps/ui.yaml
  - ingress.yaml

labels:
  - pairs:
      app.kubernetes.io/part-of: retail-store

# Secret sinh từ file .env (không commit). Tên Secret được gắn thêm hash nội dung,
# nên đổi password → hash đổi → pod tự rollout.
secretGenerator:
  - name: catalog-db
    envs: [secrets/catalog-db.env]
  - name: orders-db
    envs: [secrets/orders-db.env]
  - name: rabbitmq
    envs: [secrets/rabbitmq.env]

# Manifest dùng tên image "giả"; Kustomize thay bằng image thật + tag ở đây
images:
  - name: retail-store/catalog
    newName: ghcr.io/dwchwang/retail-store-catalog
    newTag: "0.1.0"
  - name: retail-store/cart
    newName: ghcr.io/dwchwang/retail-store-cart
    newTag: "0.1.0"
  - name: retail-store/orders
    newName: ghcr.io/dwchwang/retail-store-orders
    newTag: "0.1.0"
  - name: retail-store/checkout
    newName: ghcr.io/dwchwang/retail-store-checkout
    newTag: "0.1.0"
  - name: retail-store/ui
    newName: ghcr.io/dwchwang/retail-store-ui
    newTag: "0.1.0"
```

**`k8s/namespace.yaml`**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: retail-store
```

### Secret
```bash
cd k8s/secrets
printf 'password=%s\nroot-password=%s\n' "$(openssl rand -hex 16)" "$(openssl rand -hex 16)" > catalog-db.env
printf 'password=%s\n' "$(openssl rand -hex 16)" > orders-db.env
printf 'password=%s\n' "$(openssl rand -hex 16)" > rabbitmq.env
for f in catalog-db orders-db rabbitmq; do sed 's/=.*/=change-me/' $f.env > $f.env.example; done
cd -
```
> Secret của K8s chỉ được **base64**, không phải mã hoá: ai có quyền đọc Secret là đọc được password. Ở GĐ4 sẽ dùng Sealed Secrets để mã hoá thật và commit được.

---

## Bước 3 – Data stores (StatefulSet + PVC trên Longhorn)

**Vì sao DB dùng StatefulSet mà không dùng Deployment?**
| | Deployment | StatefulSet |
|---|---|---|
| Tên pod | Ngẫu nhiên (`orders-7f9c-xk2`) | Cố định (`orders-db-0`) |
| Ổ đĩa | Dùng chung một PVC, hoặc không có | **Mỗi pod một PVC riêng** (`volumeClaimTemplates`), pod tạo lại vẫn gắn đúng PVC cũ |
| Thứ tự | Song song | Lần lượt `-0`, `-1`… |
| Service | ClusterIP | **Headless** (`clusterIP: None`): DNS trỏ thẳng tới pod |

**Lưu ý:** volume Longhorn dùng ext4 nên luôn có sẵn thư mục `lost+found`. Postgres và MariaDB **từ chối khởi tạo vào thư mục không trống**. Vì vậy cần trỏ data vào thư mục con: `PGDATA` cho Postgres, `subPath` cho MariaDB.

**`k8s/data/catalog-db.yaml`**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: catalog-db
spec:
  clusterIP: None
  selector:
    app: catalog-db
  ports:
    - name: mysql
      port: 3306
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: catalog-db
spec:
  serviceName: catalog-db
  replicas: 1
  selector:
    matchLabels:
      app: catalog-db
  template:
    metadata:
      labels:
        app: catalog-db
    spec:
      containers:
        - name: mariadb
          image: mariadb:10.11
          ports:
            - name: mysql
              containerPort: 3306
          env:
            - name: MARIADB_DATABASE
              value: catalogdb
            - name: MARIADB_USER
              value: catalog_user
            - name: MARIADB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: catalog-db
                  key: password
            - name: MARIADB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: catalog-db
                  key: root-password
          volumeMounts:
            - name: data
              mountPath: /var/lib/mysql
              subPath: mysql
          readinessProbe:
            exec:
              command: ["healthcheck.sh", "--connect", "--innodb_initialized"]
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            exec:
              command: ["healthcheck.sh", "--connect"]
            initialDelaySeconds: 60
            periodSeconds: 20
            timeoutSeconds: 5
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 512Mi
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 2Gi
```

**`k8s/data/orders-db.yaml`**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: orders-db
spec:
  clusterIP: None
  selector:
    app: orders-db
  ports:
    - name: postgres
      port: 5432
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: orders-db
spec:
  serviceName: orders-db
  replicas: 1
  selector:
    matchLabels:
      app: orders-db
  template:
    metadata:
      labels:
        app: orders-db
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - name: postgres
              containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: orders
            - name: POSTGRES_USER
              value: orders_user
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: orders-db
                  key: password
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "orders_user", "-d", "orders"]
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "orders_user", "-d", "orders"]
            initialDelaySeconds: 30
            periodSeconds: 20
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 512Mi
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 2Gi
```

**`k8s/data/rabbitmq.yaml`**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: rabbitmq
spec:
  clusterIP: None
  selector:
    app: rabbitmq
  ports:
    - name: amqp
      port: 5672
    - name: management
      port: 15672
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: rabbitmq
spec:
  serviceName: rabbitmq
  replicas: 1
  selector:
    matchLabels:
      app: rabbitmq
  template:
    metadata:
      labels:
        app: rabbitmq
    spec:
      containers:
        - name: rabbitmq
          image: rabbitmq:3.13-management-alpine
          ports:
            - name: amqp
              containerPort: 5672
            - name: management
              containerPort: 15672
          env:
            - name: RABBITMQ_DEFAULT_USER
              value: orders
            - name: RABBITMQ_DEFAULT_PASS
              valueFrom:
                secretKeyRef:
                  name: rabbitmq
                  key: password
          volumeMounts:
            - name: data
              mountPath: /var/lib/rabbitmq
          readinessProbe:
            exec:
              command: ["rabbitmq-diagnostics", "-q", "check_port_connectivity"]
            initialDelaySeconds: 20
            periodSeconds: 15
            timeoutSeconds: 10
          livenessProbe:
            exec:
              command: ["rabbitmq-diagnostics", "-q", "ping"]
            initialDelaySeconds: 60
            periodSeconds: 30
            timeoutSeconds: 15
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 512Mi
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
```

**`k8s/data/cart-db.yaml`**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: cart-db
spec:
  clusterIP: None
  selector:
    app: cart-db
  ports:
    - name: http
      port: 8000
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: cart-db
spec:
  serviceName: cart-db
  replicas: 1
  selector:
    matchLabels:
      app: cart-db
  template:
    metadata:
      labels:
        app: cart-db
    spec:
      securityContext:
        runAsUser: 0          # image ghi vào volume cần quyền root (giống compose)
      containers:
        - name: dynamodb
          image: amazon/dynamodb-local:2.6.0
          workingDir: /home/dynamodblocal
          args: ["-jar", "DynamoDBLocal.jar", "-sharedDb", "-dbPath", "/data"]
          ports:
            - name: http
              containerPort: 8000
          volumeMounts:
            - name: data
              mountPath: /data
          readinessProbe:
            tcpSocket:
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 8000
            initialDelaySeconds: 30
            periodSeconds: 20
          resources:
            requests:
              cpu: 50m
              memory: 256Mi
            limits:
              memory: 512Mi
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
```

**`k8s/data/checkout-redis.yaml`**: Redis chỉ giữ session checkout tạm thời, nên dùng Deployment, không cần PVC.
```yaml
apiVersion: v1
kind: Service
metadata:
  name: checkout-redis
spec:
  selector:
    app: checkout-redis
  ports:
    - name: redis
      port: 6379
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-redis
spec:
  replicas: 1
  selector:
    matchLabels:
      app: checkout-redis
  template:
    metadata:
      labels:
        app: checkout-redis
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: redis
          image: redis:7-alpine
          args: ["--save", "", "--appendonly", "no"]
          ports:
            - name: redis
              containerPort: 6379
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: data
              mountPath: /data
          readinessProbe:
            exec:
              command: ["redis-cli", "ping"]
            periodSeconds: 5
          livenessProbe:
            exec:
              command: ["redis-cli", "ping"]
            initialDelaySeconds: 10
            periodSeconds: 15
          resources:
            requests:
              cpu: 20m
              memory: 32Mi
            limits:
              memory: 128Mi
      volumes:
        - name: data
          emptyDir: {}
```

---

## Bước 4 – Apps (Deployment + Service + ConfigMap)

**Khuôn chung cho mọi app:**

| Thành phần | Thiết lập | Vì sao |
|---|---|---|
| **ConfigMap** | Endpoint, provider | Cấu hình không bí mật, tách khỏi image |
| **Secret** | Chỉ password, gắn qua `secretKeyRef` | Mỗi app chỉ đọc đúng secret nó cần |
| **startupProbe** | Java: chờ tối đa khoảng 3 phút | JVM khởi động chậm. Thiếu probe này, liveness sẽ giết pod trước khi app kịp chạy |
| **readinessProbe** | Fail thì Service **ngừng gửi traffic** tới pod | Pod chưa sẵn sàng không nhận request |
| **livenessProbe** | Fail thì **restart** container | App treo thì tự hồi phục |
| **resources** | Có `requests` CPU/RAM; có `limits` cho **RAM**, **không** đặt limit CPU | Scheduler xếp pod dựa trên requests. Limit CPU gây throttle, Java khởi động chậm hẳn |
| **securityContext** | non-root, root filesystem read-only, drop ALL capabilities | Giống compose ở GĐ1 |
| **`runAsUser` dạng số** | catalog `65532`, các app khác `1000` | Image khai `USER nonroot`/`app` bằng tên; kubelet không xác minh được `runAsNonRoot` nếu không có UID dạng số → pod lỗi `CreateContainerConfigError` |
| **emptyDir `/tmp`** | | Root filesystem read-only nhưng Tomcat/Node cần ghi file tạm |

Spring Boot tự bật endpoint `/actuator/health/liveness` và `/readiness` khi phát hiện đang chạy trong K8s. Biến `MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED` dưới đây đặt ra để chắc chắn.

**`k8s/apps/catalog.yaml`**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: catalog
data:
  RETAIL_CATALOG_PERSISTENCE_PROVIDER: mysql
  RETAIL_CATALOG_PERSISTENCE_ENDPOINT: catalog-db:3306
  RETAIL_CATALOG_PERSISTENCE_DB_NAME: catalogdb
  RETAIL_CATALOG_PERSISTENCE_USER: catalog_user
---
apiVersion: v1
kind: Service
metadata:
  name: catalog
spec:
  selector:
    app: catalog
  ports:
    - name: http
      port: 8080
      targetPort: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog
spec:
  replicas: 1
  selector:
    matchLabels:
      app: catalog
  template:
    metadata:
      labels:
        app: catalog
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: catalog
          image: retail-store/catalog
          ports:
            - name: http
              containerPort: 8080
          envFrom:
            - configMapRef:
                name: catalog
          env:
            - name: RETAIL_CATALOG_PERSISTENCE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: catalog-db
                  key: password
          readinessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 10
            periodSeconds: 20
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 128Mi
```

**`k8s/apps/cart.yaml`**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cart
data:
  RETAIL_CART_PERSISTENCE_PROVIDER: dynamodb
  RETAIL_CART_PERSISTENCE_DYNAMODB_ENDPOINT: http://cart-db:8000
  RETAIL_CART_PERSISTENCE_DYNAMODB_CREATE_TABLE: "true"
  AWS_REGION: us-east-1
  AWS_ACCESS_KEY_ID: local          # DynamoDB Local chấp nhận key bất kỳ
  AWS_SECRET_ACCESS_KEY: local
  MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED: "true"
---
apiVersion: v1
kind: Service
metadata:
  name: cart
spec:
  selector:
    app: cart
  ports:
    - name: http
      port: 8080
      targetPort: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cart
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cart
  template:
    metadata:
      labels:
        app: cart
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: cart
          image: retail-store/cart
          ports:
            - name: http
              containerPort: 8080
          envFrom:
            - configMapRef:
                name: cart
          startupProbe:
            httpGet:
              path: /actuator/health/liveness
              port: http
            periodSeconds: 5
            failureThreshold: 36
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: http
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: http
            periodSeconds: 20
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
          resources:
            requests:
              cpu: 100m
              memory: 384Mi
            limits:
              memory: 768Mi
      volumes:
        - name: tmp
          emptyDir: {}
```

**`k8s/apps/orders.yaml`**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: orders
data:
  RETAIL_ORDERS_PERSISTENCE_PROVIDER: postgres
  RETAIL_ORDERS_PERSISTENCE_ENDPOINT: orders-db:5432
  RETAIL_ORDERS_PERSISTENCE_NAME: orders
  RETAIL_ORDERS_PERSISTENCE_USERNAME: orders_user
  RETAIL_ORDERS_MESSAGING_PROVIDER: rabbitmq
  RETAIL_ORDERS_MESSAGING_RABBITMQ_ADDRESSES: rabbitmq:5672
  RETAIL_ORDERS_MESSAGING_RABBITMQ_USERNAME: orders
  MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED: "true"
---
apiVersion: v1
kind: Service
metadata:
  name: orders
spec:
  selector:
    app: orders
  ports:
    - name: http
      port: 8080
      targetPort: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders
spec:
  replicas: 1
  selector:
    matchLabels:
      app: orders
  template:
    metadata:
      labels:
        app: orders
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: orders
          image: retail-store/orders
          ports:
            - name: http
              containerPort: 8080
          envFrom:
            - configMapRef:
                name: orders
          env:
            - name: RETAIL_ORDERS_PERSISTENCE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: orders-db
                  key: password
            - name: RETAIL_ORDERS_MESSAGING_RABBITMQ_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: rabbitmq
                  key: password
          startupProbe:
            httpGet:
              path: /actuator/health/liveness
              port: http
            periodSeconds: 5
            failureThreshold: 36
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: http
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: http
            periodSeconds: 20
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
          resources:
            requests:
              cpu: 100m
              memory: 384Mi
            limits:
              memory: 768Mi
      volumes:
        - name: tmp
          emptyDir: {}
```

**`k8s/apps/checkout.yaml`**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: checkout
data:
  RETAIL_CHECKOUT_PERSISTENCE_PROVIDER: redis
  RETAIL_CHECKOUT_PERSISTENCE_REDIS_URL: redis://checkout-redis:6379
  RETAIL_CHECKOUT_ENDPOINTS_ORDERS: http://orders:8080
---
apiVersion: v1
kind: Service
metadata:
  name: checkout
spec:
  selector:
    app: checkout
  ports:
    - name: http
      port: 8080
      targetPort: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
spec:
  replicas: 1
  selector:
    matchLabels:
      app: checkout
  template:
    metadata:
      labels:
        app: checkout
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: checkout
          image: retail-store/checkout
          ports:
            - name: http
              containerPort: 8080
          envFrom:
            - configMapRef:
                name: checkout
          readinessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 15
            periodSeconds: 20
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 256Mi
      volumes:
        - name: tmp
          emptyDir: {}
```

**`k8s/apps/ui.yaml`**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ui
data:
  RETAIL_UI_ENDPOINTS_CATALOG: http://catalog:8080
  RETAIL_UI_ENDPOINTS_CARTS: http://cart:8080
  RETAIL_UI_ENDPOINTS_ORDERS: http://orders:8080
  RETAIL_UI_ENDPOINTS_CHECKOUT: http://checkout:8080
  MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED: "true"
---
apiVersion: v1
kind: Service
metadata:
  name: ui
spec:
  selector:
    app: ui
  ports:
    - name: http
      port: 8080
      targetPort: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ui
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ui
  template:
    metadata:
      labels:
        app: ui
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: ui
          image: retail-store/ui
          ports:
            - name: http
              containerPort: 8080
          envFrom:
            - configMapRef:
                name: ui
          startupProbe:
            httpGet:
              path: /actuator/health/liveness
              port: http
            periodSeconds: 5
            failureThreshold: 36
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: http
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: http
            periodSeconds: 20
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
          resources:
            requests:
              cpu: 100m
              memory: 384Mi
            limits:
              memory: 768Mi
      volumes:
        - name: tmp
          emptyDir: {}
```

---

## Bước 5 – Ingress (Traefik)

**`k8s/ingress.yaml`**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ui
spec:
  ingressClassName: traefik
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ui
                port:
                  number: 8080
```
Rule không có `host` nên mọi domain hoặc IP trỏ vào đều tới UI. Muốn có tên miền mà không cần mua DNS, thêm `host: retail.<EIP>.nip.io`: dịch vụ nip.io tự phân giải tên đó về đúng IP trong tên.

---

## Bước 6 – Deploy và kiểm tra

```bash
kubectl kustomize k8s | less           # xem manifest cuối cùng sau khi Kustomize render
kubectl apply -f k8s/namespace.yaml    # tạo namespace thật trước: dry-run không lưu gì,
                                       # nên thiếu bước này các object khác báo "namespaces not found"
kubectl apply -k k8s --dry-run=server  # API server kiểm tra hợp lệ, chưa tạo gì
kubectl apply -k k8s

kubectl -n retail-store get pods -w    # chờ tất cả Running và READY 1/1 (khoảng 3–5 phút)
kubectl -n retail-store get pvc        # 4 PVC Bound
```
App có thể restart 1–2 lần lúc đầu vì DB chưa sẵn sàng. Đây là chuyện **bình thường**: K8s tự restart cho tới khi DB lên. Sau khoảng 5 phút mà vẫn `CrashLoopBackOff` thì xem mục Debug bên dưới.

**Smoke test:**
```bash
EIP=$(terraform -chdir=infra/terraform/main output -raw server_public_ip)
curl -s -o /dev/null -w '%{http_code}\n' http://$EIP/      # 200
open http://$EIP/                                          # thêm vào giỏ → checkout → đặt hàng
```
Kiểm tra đơn hàng trong DB:
```bash
kubectl -n retail-store exec orders-db-0 -- psql -U orders_user -d orders -c 'select id, created_date from orders;'
```

### DoD Phần 1
- [ ] Tất cả pod `Running` và `READY`, 4 PVC `Bound`
- [ ] Đặt hàng thành công qua `http://<EIP>/`, đơn hàng có trong Postgres
- [ ] **Xoá pod DB, dữ liệu vẫn còn:**
  ```bash
  kubectl -n retail-store delete pod orders-db-0
  kubectl -n retail-store get pod orders-db-0 -w     # pod tạo lại, gắn lại đúng PVC cũ
  # chạy lại câu lệnh psql ở trên → đơn hàng cũ vẫn còn
  ```
- [ ] Không có pod nào chạy bằng root (trừ 4 image DB chính thức):
  ```bash
  kubectl -n retail-store get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.securityContext.runAsUser}{"\n"}{end}'
  ```

---

## Debug: các lệnh theo thứ tự nên dùng

```bash
kubectl -n retail-store get pods                         # STATUS và RESTARTS
kubectl -n retail-store describe pod <pod>               # phần Events ở cuối: lỗi pull image, probe, OOM
kubectl -n retail-store logs <pod> --previous            # log của lần chạy TRƯỚC khi crash
kubectl -n retail-store get events --sort-by=.lastTimestamp | tail -20
kubectl -n retail-store exec -it deploy/ui -- sh         # image có shell (catalog dùng distroless thì không có)
kubectl -n retail-store port-forward svc/rabbitmq 15672  # mở RabbitMQ UI trên laptop
```

| Triệu chứng | Nguyên nhân thường gặp |
|---|---|
| `ImagePullBackOff` | Package GHCR vẫn private; sai tên hoặc tag; image không phải amd64 |
| `exec format error` | Image build cho arm64 → build lại với `--platform linux/amd64` |
| `CreateContainerConfigError` + `non-numeric user` | Thiếu `runAsUser` dạng số |
| `CreateContainerConfigError` + `secret not found` | Chưa tạo file `.env` trong `k8s/secrets/` |
| `OOMKilled` | Limit RAM quá thấp → tăng `limits.memory` |
| Pod `Pending` | `describe` để xem: thiếu RAM trên node (`Insufficient memory`) hoặc PVC chưa Bound |
| Postgres hoặc MariaDB báo `directory not empty` | Thiếu `PGDATA` hoặc `subPath` (do `lost+found`) |
| UI hiện sản phẩm giả / đơn hàng không vào DB | Sai endpoint trong ConfigMap → app tự dùng mock |
| `curl http://<EIP>/` bị timeout | Traefik không có hostPort → xem mục dưới |

**Traefik không có hostPort** (Service ở trạng thái `LoadBalancer <pending>`): tạm dùng NodePort.
```bash
kubectl -n kube-system get svc rke2-traefik     # xem cột PORT(S), ví dụ 80:3xxxx/TCP
```
Cách 1: truy cập `http://<EIP>:3xxxx`. Phải mở thêm dải `30000-32767` cho IP của bạn trong `security.tf`.
Cách 2: cấu hình hostPort cho Traefik bằng `HelmChartConfig` của RKE2. Cách này đúng chuẩn hơn; hỏi tôi khi gặp trường hợp này.

---

## Dọn dẹp cuối buổi
```bash
kubectl delete -k k8s          # tuỳ chọn: xoá app, PVC cũng bị xoá theo namespace
terraform -chdir=infra/terraform/main destroy
```
💰 Push image lên GHCR không tốn tiền AWS. Cluster vẫn tốn khoảng $0.23/giờ khi đang chạy.

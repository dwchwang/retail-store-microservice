# GĐ3 – Đọc hiểu manifest YAML của Kubernetes

> Đọc cùng thư mục `k8s/` và guide [gd3-01-k8s-manifests.md](../guides/gd3-01-k8s-manifests.md). File [gd3-kubernetes.md](gd3-kubernetes.md) giải thích **khái niệm**; file này giải thích **cách viết**: từng dòng YAML nghĩa là gì, các phần nối với nhau thế nào, và tự viết manifest mới ra sao.

---

## 0. Trả lời trước: cách viết này chung hay riêng cho RKE2?

**Gần như toàn bộ là YAML Kubernetes chuẩn (upstream).** Cùng các file này apply lên EKS, GKE, AKS, k3s, kubeadm, minikube đều được. RKE2 là một bản phân phối Kubernetes đạt chứng nhận CNCF, nên nó hiểu đúng API như mọi cluster khác.

Chỉ một vài **giá trị** phụ thuộc vào thứ được cài trong cluster, còn **cú pháp** thì không:

| Chỗ trong manifest | Phụ thuộc vào | Trên cluster khác |
|---|---|---|
| `ingressClassName: traefik` | Ingress Controller đang cài (RKE2 v1.36 cài Traefik) | ingress-nginx: `nginx`; EKS + AWS LB Controller: `alb` |
| PVC không ghi `storageClassName` | StorageClass **mặc định** của cluster (bạn đặt Longhorn ở GĐ2) | EKS: `gp3`/`gp2` (EBS); minikube: `standard` |
| Ingress truy cập được qua `http://<IP node>/` | Traefik của RKE2 chạy hostPort 80/443 | Cloud: Service `LoadBalancer` tạo ELB; on-prem: MetalLB |
| `runAsUser: 1000` / `65532` | UID trong **image** của bạn | Giống nhau ở mọi nơi (phụ thuộc image, không phụ thuộc cluster) |
| `kustomization.yaml` | `kubectl` (Kustomize có sẵn) | Giống nhau ở mọi nơi |

**Kết luận:** học cách viết ở đây là dùng được ở mọi công ty. Chuyển sang cluster khác thường chỉ phải đổi `ingressClassName` và có thể là `storageClassName`.

---

## 1. YAML tối thiểu cần biết

YAML chỉ có 3 kiểu dữ liệu: **map** (key: value), **list** (gạch đầu dòng) và **giá trị đơn** (chuỗi, số, bool).

```yaml
name: orders            # map: key "name" có giá trị "orders"
replicas: 1             # số
enabled: true           # bool
labels:                 # map lồng: thụt vào 2 dấu cách
  app: orders
ports:                  # list: mỗi phần tử bắt đầu bằng "- "
  - name: http          #   phần tử 1 là một map có 2 key
    containerPort: 8080
  - name: metrics       #   phần tử 2
    containerPort: 9090
args: ["-jar", "app.jar"]   # list viết gọn trên một dòng (giống JSON)
drop: ["ALL"]
emptyDir: {}            # map rỗng
---                     # ngăn cách nhiều "document" (nhiều object) trong một file
```

**Quy tắc dễ sai:**
- **Thụt lề bằng dấu cách, không dùng tab.** Mức thụt lề quyết định cái gì thuộc về cái gì. Lỗi `mapping values are not allowed` hồi GĐ2 chính là do thụt lề sai.
- `- name: http` và `containerPort: 8080` ở dòng dưới phải **thẳng cột** với nhau (cùng thuộc một phần tử list).
- **Chuỗi trông giống số hoặc bool phải để trong ngoặc kép** khi K8s đòi kiểu chuỗi. Ví dụ trong ConfigMap: `CREATE_TABLE: "true"`, `newTag: "0.1.0"`. Viết `true` không ngoặc thì YAML hiểu là bool, và API server báo lỗi vì `data` của ConfigMap chỉ nhận chuỗi.
- Biến môi trường `env[].value` cũng phải là chuỗi: `value: "8080"`, không phải `value: 8080`.

---

## 2. Bộ khung chung của MỌI object Kubernetes

Mọi file manifest, dù là Service, Deployment hay Ingress, đều có cùng 4 phần:

```yaml
apiVersion: apps/v1        # ① API nào, phiên bản nào
kind: Deployment           # ② loại object
metadata:                  # ③ danh tính: tên, namespace, label
  name: orders
  labels:
    app: orders
spec:                      # ④ trạng thái MONG MUỐN (bạn viết)
  ...
# status:                  # ⑤ trạng thái THỰC TẾ (K8s tự ghi, bạn không viết)
```

### ① `apiVersion`: nhóm API / phiên bản
API của K8s chia thành **nhóm**. Mỗi `kind` thuộc một nhóm cố định:

| apiVersion | Gồm các kind | Ghi chú |
|---|---|---|
| `v1` | Pod, Service, ConfigMap, Secret, Namespace, PersistentVolumeClaim | Nhóm "core", không có tiền tố |
| `apps/v1` | Deployment, StatefulSet, DaemonSet, ReplicaSet | |
| `networking.k8s.io/v1` | Ingress, NetworkPolicy, IngressClass | |
| `autoscaling/v2` | HorizontalPodAutoscaler | Phần 3 |
| `batch/v1` | Job, CronJob | Phần 3 |
| `policy/v1` | PodDisruptionBudget | Phần 3 |
| `kustomize.config.k8s.io/v1beta1` | Kustomization | **Không phải object K8s**, chỉ `kubectl kustomize` đọc |

Không cần học thuộc. Tra bằng:
```bash
kubectl api-resources | grep -i ingress
# ingresses   ing   networking.k8s.io/v1   true   Ingress
```

### ③ `metadata`
- `name`: duy nhất **trong cùng namespace và cùng kind**. Vì vậy Service `orders` và Deployment `orders` trùng tên được, vì khác kind.
- `namespace`: các file trong dự án **không ghi**, vì `kustomization.yaml` có `namespace: retail-store` gắn vào cho tất cả.
- `labels`: các cặp key/value tự đặt, dùng để **chọn** object (xem §3).

### ④ `spec` và ⑤ `status`
Bạn chỉ viết `spec`. Controller đọc `spec`, làm việc, rồi ghi kết quả vào `status`. Xem bằng `kubectl get deploy orders -o yaml`: phần cuối có `status:` với `readyReplicas`, `conditions`.

**Cấu trúc bên trong `spec` thì mỗi kind một khác.** Tra cứu tại chỗ:
```bash
kubectl explain deployment.spec
kubectl explain statefulset.spec.volumeClaimTemplates
kubectl explain pod.spec.containers.readinessProbe --recursive | less
```
`kubectl explain` lấy schema trực tiếp từ API server của bạn, nên luôn đúng phiên bản. Đây là công cụ quan trọng nhất khi tự viết YAML.

---

## 3. Sợi dây nối các object: tên và label

Một file YAML trông như nhiều khối rời rạc, nhưng thực ra các khối **trỏ vào nhau** bằng 2 cách:
- **Bằng label** (một-nhiều, động): Service và Deployment tìm pod.
- **Bằng tên** (một-một, cố định): pod tìm ConfigMap, Secret, volume, port.

Sơ đồ đầy đủ cho `orders` (app) và `orders-db` (data):

```
                        ┌──────────── kustomization.yaml ────────────┐
                        │ secretGenerator: name: orders-db           │
                        │ images: name: retail-store/orders          │
                        └──────┬──────────────────────┬──────────────┘
                               │ (tên)                │ (thay image)
apps/orders.yaml               ▼                      ▼
┌─ ConfigMap ─────────┐   ┌─ Deployment orders ──────────────────────────┐
│ name: orders  ◀─────┼───┤ envFrom.configMapRef.name: orders            │
│ data:               │   │ env.valueFrom.secretKeyRef.name: orders-db ──┼──▶ Secret orders-db-<hash>
│   ..._ENDPOINT:     │   │ image: retail-store/orders                   │       key: password
│   orders-db:5432 ───┼─┐ │ selector.matchLabels: {app: orders} ──┐      │
└─────────────────────┘ │ │ template.metadata.labels:{app: orders}◀┘     │
┌─ Service orders ────┐ │ │   ports: - name: http ◀───────┐              │
│ selector:           │ │ │           containerPort: 8080 │              │
│   app: orders ──────┼─┼─┼──▶ (mọi pod có label này)    │              │
│ targetPort: http ───┼─┼─┼──────────────────────────────┘              │
└─────────────────────┘ │ └──────────────────────────────────────────────┘
                        │ (DNS: tên Service)
data/orders-db.yaml     ▼
┌─ Service orders-db ─┐   ┌─ StatefulSet orders-db ──────────────────────┐
│ clusterIP: None     │◀──┤ serviceName: orders-db                       │
│ selector:           │   │ selector.matchLabels: {app: orders-db}       │
│   app: orders-db ───┼──▶│ template.metadata.labels: {app: orders-db}   │
└─────────────────────┘   │   volumeMounts: - name: data ◀─┐             │
                          │ volumeClaimTemplates:           │             │
                          │   - metadata.name: data ────────┘             │
                          └──────────────────────────────────────────────┘
ingress.yaml
┌─ Ingress ui ─────────────────────────┐
│ backend.service.name: ui  ───────────┼──▶ Service ui
│ backend.service.port.number: 8080    │       port: 8080
└──────────────────────────────────────┘
```

**Hệ quả quan trọng:** gõ sai một tên hay một label thì `kubectl apply` **vẫn thành công**, vì K8s không kiểm tra các liên kết này lúc apply. Lỗi chỉ lộ ra lúc chạy:

| Gõ sai ở đâu | Triệu chứng |
|---|---|
| Label trong `selector` của Service | Pod chạy bình thường, nhưng `kubectl get endpoints <svc>` trống, gọi vào bị timeout |
| `selector` của Deployment khác `template.labels` | Apply **bị từ chối** (trường hợp duy nhất được kiểm tra) |
| Tên ConfigMap/Secret | Pod lỗi `CreateContainerConfigError` |
| `key` trong `secretKeyRef` | `CreateContainerConfigError`: `couldn't find key` |
| Tên trong `volumeMounts` khác `volumes`/`volumeClaimTemplates` | Apply bị từ chối: `volumeMounts[0].name: Not found` |
| `targetPort: http` mà container không có port tên `http` | Service không có endpoint |
| Tên Service trong ConfigMap (`orders-db:5432`) | App log `UnknownHostException` rồi crash |

---

## 4. "Template": Deployment và StatefulSet chứa một Pod bên trong

Đây là chỗ hay gây rối nhất: vì sao có **hai** `metadata` và **hai** `spec` lồng nhau?

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:                 # ← metadata của DEPLOYMENT
  name: orders
spec:                     # ← spec của DEPLOYMENT: "quản lý pod thế nào"
  replicas: 1
  selector:
    matchLabels:
      app: orders
  template:               # ═══ khuôn để ĐÚC RA POD ═══
    metadata:             # ← metadata của POD (mỗi pod đúc ra đều có label này)
      labels:
        app: orders
    spec:                 # ← spec của POD: "pod chạy gì"
      securityContext: ...
      containers: [...]
      volumes: [...]
```

`template` là **một Pod hoàn chỉnh, chỉ bỏ đi `apiVersion` và `kind`**. Deployment controller lấy khuôn này để tạo pod. Vì thế:
- Mọi thứ bạn học về Pod (`containers`, `volumes`, `securityContext`, probe) đều viết trong `spec.template.spec`.
- Cùng một khuôn Pod xuất hiện y hệt trong Deployment, StatefulSet, DaemonSet, Job, CronJob. Học một lần, dùng cho cả 5.
- Sửa bất kỳ thứ gì trong `template` (image, env, label) thì Deployment coi là **phiên bản mới** và rolling update. Sửa `replicas` thì không, vì `replicas` nằm ngoài template.

Cây đầy đủ của một Deployment trong dự án:
```
Deployment
├── metadata.name
└── spec
    ├── replicas
    ├── selector.matchLabels          ← phải khớp template.metadata.labels
    └── template                      ← = Pod
        ├── metadata.labels
        └── spec                      ← Pod spec
            ├── securityContext       ← cấp POD (mọi container)
            ├── containers[]
            │   ├── name, image
            │   ├── ports[]
            │   ├── envFrom[], env[]
            │   ├── startupProbe / readinessProbe / livenessProbe
            │   ├── securityContext   ← cấp CONTAINER
            │   ├── volumeMounts[]    ← "gắn volume tên X vào đường dẫn Y"
            │   └── resources
            └── volumes[]             ← "volume tên X lấy từ đâu"
```

StatefulSet có cùng cây, thêm 2 trường: `serviceName` và `volumeClaimTemplates` (nằm **ngang hàng** với `template`, không nằm trong nó).

---

## 5. Đọc từng dòng: `data/orders-db.yaml` (Service headless + StatefulSet)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: orders-db          # tên này thành DNS "orders-db" trong namespace
spec:
  clusterIP: None          # HEADLESS: không cấp IP ảo; DNS trả về thẳng IP pod
  selector:
    app: orders-db         # gom mọi pod có label app=orders-db
  ports:
    - name: postgres
      port: 5432           # port mà client gọi (orders gọi orders-db:5432)
                           # không ghi targetPort → mặc định = port
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: orders-db          # pod sẽ tên orders-db-0, orders-db-1...
spec:
  serviceName: orders-db   # Service headless ở trên; sinh DNS orders-db-0.orders-db
  replicas: 1
  selector:
    matchLabels:
      app: orders-db       # StatefulSet quản lý pod có label này
  template:
    metadata:
      labels:
        app: orders-db     # pod đúc ra mang label này → khớp cả selector lẫn Service
    spec:
      containers:
        - name: postgres                 # tên container (dùng cho kubectl logs -c)
          image: postgres:16-alpine      # image chính thức trên Docker Hub
          ports:
            - name: postgres
              containerPort: 5432        # chỉ là "tài liệu" + đặt tên port;
                                         # app nghe port nào là do app quyết định
          env:
            - name: POSTGRES_DB          # biến do image postgres định nghĩa:
              value: orders              # lần đầu chạy sẽ tạo DB tên "orders"
            - name: POSTGRES_USER
              value: orders_user
            - name: POSTGRES_PASSWORD
              valueFrom:                 # lấy giá trị từ nơi khác thay vì ghi thẳng
                secretKeyRef:
                  name: orders-db        # Secret tên orders-db (Kustomize thêm hash)
                  key: password          # key "password" trong file orders-db.env
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata   # né thư mục lost+found
          volumeMounts:
            - name: data                 # volume tên "data" (định nghĩa ở dưới)
              mountPath: /var/lib/postgresql/data      # gắn vào đường dẫn này
          readinessProbe:
            exec:                        # chạy lệnh bên trong container
              command: ["pg_isready", "-U", "orders_user", "-d", "orders"]
            initialDelaySeconds: 5       # chờ 5s sau khi container start
            periodSeconds: 10            # kiểm tra mỗi 10s
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "orders_user", "-d", "orders"]
            initialDelaySeconds: 30
            periodSeconds: 20
          resources:
            requests:                    # scheduler giữ chỗ chừng này trên node
              cpu: 100m                  # 100 millicore = 0.1 CPU
              memory: 256Mi              # Mi = mebibyte (1024²), khác M (1000²)
            limits:
              memory: 512Mi              # vượt là OOMKilled
  volumeClaimTemplates:                  # ngang hàng với template, KHÔNG nằm trong
    - metadata:
        name: data                       # ← khớp volumeMounts.name ở trên
      spec:                              # đây là spec của một PVC
        accessModes: ["ReadWriteOnce"]   # một node mount tại một thời điểm
        resources:
          requests:
            storage: 2Gi                 # không ghi storageClassName → dùng default (Longhorn)
```

**Những biến `POSTGRES_*`, `MARIADB_*`, `RABBITMQ_DEFAULT_*` lấy ở đâu ra?** Không phải của K8s. Chúng do **image** quy định, và tài liệu nằm trên trang Docker Hub của image đó (hub.docker.com/_/postgres → mục *Environment Variables*). K8s chỉ chuyển chúng vào container, giống `environment:` trong compose.

**Tên PVC thực tế** = `<tên volumeClaimTemplate>-<tên pod>` = `data-orders-db-0`. Kiểm tra bằng `kubectl -n retail-store get pvc`.

### Các data store còn lại khác gì

**`catalog-db.yaml` (MariaDB):**
```yaml
volumeMounts:
  - name: data
    mountPath: /var/lib/mysql
    subPath: mysql            # chỉ gắn thư mục con "mysql/" của volume, né lost+found
```
`subPath` dùng được cho mọi image. `PGDATA` chỉ có ở Postgres. Probe dùng `healthcheck.sh`, một script có sẵn trong image MariaDB ≥ 10.4.

**`rabbitmq.yaml`:** Service khai **2 port** (`amqp` 5672 cho app, `management` 15672 cho giao diện web). Một Service có bao nhiêu port cũng được, mỗi port nên có `name`.

**`cart-db.yaml` (DynamoDB Local):**
```yaml
securityContext:
  runAsUser: 0                     # chạy root: image cần quyền ghi vào volume
containers:
  - workingDir: /home/dynamodblocal
    args: ["-jar", "DynamoDBLocal.jar", "-sharedDb", "-dbPath", "/data"]
```
Đối chiếu với Dockerfile:

| K8s | Dockerfile | Ghi đè thế nào |
|---|---|---|
| `command:` | `ENTRYPOINT` | Có `command` thì bỏ ENTRYPOINT của image |
| `args:` | `CMD` | Có `args` thì bỏ CMD của image, giữ ENTRYPOINT |
| `workingDir:` | `WORKDIR` | |

Image DynamoDB Local có `ENTRYPOINT ["java"]`, nên chỉ cần thay `args` để thêm `-dbPath /data` (mặc định nó lưu trong RAM). Probe dùng `tcpSocket` vì image không có `curl`.

**`checkout-redis.yaml`:** là **Deployment** (không phải StatefulSet), Service **không** có `clusterIP: None`, volume là `emptyDir`:
```yaml
volumes:
  - name: data
    emptyDir: {}               # thư mục tạm, mất khi pod bị xoá
```
So với StatefulSet: Deployment không có `volumeClaimTemplates`, nên volume khai ở `template.spec.volumes`.

---

## 6. Đọc từng dòng: `apps/cart.yaml` (ConfigMap + Service + Deployment)

### ConfigMap
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cart
data:                                              # toàn bộ value là CHUỖI
  RETAIL_CART_PERSISTENCE_PROVIDER: dynamodb
  RETAIL_CART_PERSISTENCE_DYNAMODB_ENDPOINT: http://cart-db:8000   # DNS = tên Service
  RETAIL_CART_PERSISTENCE_DYNAMODB_CREATE_TABLE: "true"            # phải có ngoặc kép
  MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED: "true"
```
Key đặt đúng bằng tên biến môi trường mà app cần, vì `envFrom` sẽ chép nguyên key thành tên biến. Danh sách biến lấy từ `docs/ARCHITECTURE.md` §4.

### Service
```yaml
apiVersion: v1
kind: Service
metadata:
  name: cart               # ui gọi http://cart:8080
spec:
  # không ghi type → mặc định ClusterIP (có IP ảo, chia tải)
  selector:
    app: cart
  ports:
    - name: http
      port: 8080           # port của Service (client gọi)
      targetPort: http     # port của pod: tham chiếu theo TÊN port trong container
```

### Deployment: các phần chưa gặp ở §5
```yaml
    spec:
      securityContext:                 # ── CẤP POD: áp cho mọi container
        runAsNonRoot: true             #    kubelet từ chối chạy nếu UID = 0
        runAsUser: 1000                #    UID dạng số (user "app" trong Dockerfile)
        runAsGroup: 1000
        seccompProfile:
          type: RuntimeDefault         #    lọc syscall bằng profile mặc định của containerd
      containers:
        - name: cart
          image: retail-store/cart     # tên "giả", Kustomize thay bằng ghcr.io/...:0.1.0
          envFrom:                     # chép MỌI key của ConfigMap thành biến môi trường
            - configMapRef:
                name: cart
          startupProbe:
            httpGet:                   # gọi HTTP GET vào chính pod
              path: /actuator/health/liveness
              port: http               # lại tham chiếu port theo tên
            periodSeconds: 5
            failureThreshold: 36       # 36 × 5s = 3 phút tối đa để khởi động
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
          securityContext:             # ── CẤP CONTAINER
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp          # chỗ duy nhất ghi được (root FS read-only)
          resources:
            requests:
              cpu: 100m
              memory: 384Mi
            limits:
              memory: 768Mi            # không có cpu: cố ý, tránh throttle JVM
      volumes:                         # ngang hàng với containers
        - name: tmp
          emptyDir: {}
```

**`env` và `envFrom` khác nhau thế nào:**

| | `envFrom` | `env` |
|---|---|---|
| Lấy | Toàn bộ key của ConfigMap/Secret | Từng biến một |
| Đặt tên biến | Tên biến = tên key | Tự đặt `name`, rồi trỏ tới key bất kỳ |
| Dùng trong dự án | Cấu hình (ConfigMap) | Password: `orders` cần biến `RETAIL_ORDERS_PERSISTENCE_PASSWORD` nhưng key trong Secret tên là `password`, nên phải ánh xạ bằng `env` |

Nếu một biến xuất hiện ở cả hai thì `env` thắng.

**Vì sao `securityContext` có 2 chỗ?** Một số trường **chỉ có ở cấp pod** (`fsGroup`, `seccompProfile` mặc định cho cả pod), một số **chỉ có ở cấp container** (`readOnlyRootFilesystem`, `capabilities`, `allowPrivilegeEscalation`). Trường có ở cả hai (`runAsUser`, `runAsNonRoot`) thì cấp container ghi đè cấp pod. Tra bằng `kubectl explain pod.spec.securityContext` và `kubectl explain pod.spec.containers.securityContext`.

### 5 app giống và khác nhau ở đâu
Cả 5 file app dùng **cùng một khuôn**, chỉ khác:

| | catalog | cart | orders | checkout | ui |
|---|---|---|---|---|---|
| `runAsUser` | 65532 (distroless) | 1000 | 1000 | 1000 | 1000 |
| startupProbe | không (Go khởi động < 1s) | có | có | không | có |
| Health path | `/health` | `/actuator/health/*` | `/actuator/health/*` | `/health` | `/actuator/health/*` |
| Secret qua `env` | catalog-db | không | orders-db + rabbitmq | không | không |
| emptyDir `/tmp` | không (binary Go không ghi file) | có | có | có | có |
| RAM limit | 128Mi | 768Mi | 768Mi | 256Mi | 768Mi |

Việc lặp lại gần như y hệt này chính là lý do Phần 2 dùng **Helm**: viết khuôn một lần, mỗi app chỉ khai phần khác trong `values.yaml`.

---

## 7. Đọc từng dòng: `ingress.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ui
spec:
  ingressClassName: traefik      # ★ phụ thuộc cluster: controller nào xử lý luật này
  rules:
    - http:                      # không có "host:" → áp cho mọi tên miền/IP
        paths:
          - path: /
            pathType: Prefix     # "/" khớp mọi đường dẫn bắt đầu bằng "/" (tức là tất cả)
            backend:
              service:
                name: ui         # gửi tới Service ui (cùng namespace)
                port:
                  number: 8080   # port của SERVICE, không phải của pod
```

`pathType` có 3 giá trị: `Prefix` (khớp tiền tố theo từng đoạn `/`), `Exact` (khớp chính xác), `ImplementationSpecific` (tuỳ controller).

**Ví dụ mở rộng** (chưa cần làm), có tên miền và nhiều đường dẫn:
```yaml
  rules:
    - host: retail.18.136.174.231.nip.io
      http:
        paths:
          - path: /api/catalog
            pathType: Prefix
            backend: {service: {name: catalog, port: {number: 8080}}}
          - path: /
            pathType: Prefix
            backend: {service: {name: ui, port: {number: 8080}}}
```

**Phần chung và phần riêng của Traefik:** object `Ingress` là chuẩn K8s. Traefik còn có object riêng là `IngressRoute` (`apiVersion: traefik.io/v1alpha1`) với nhiều tính năng hơn, nhưng như vậy là gắn chặt vào Traefik. Dự án dùng `Ingress` chuẩn để mang sang cluster khác được. Cấu hình riêng của controller (redirect HTTPS, rate limit) thường được thêm qua `metadata.annotations`, và annotation thì **khác nhau giữa các controller**:
```yaml
metadata:
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web   # chỉ Traefik hiểu
    # nginx.ingress.kubernetes.io/proxy-body-size: 10m      # chỉ ingress-nginx hiểu
```

---

## 8. `kustomization.yaml`: render ra cái gì

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization            # file cấu hình của Kustomize, KHÔNG gửi lên cluster
namespace: retail-store        # (1) gắn vào metadata.namespace của mọi object
resources: [...]               # (2) các file được gom lại theo thứ tự
labels:
  - pairs:
      app.kubernetes.io/part-of: retail-store   # (3) thêm label vào mọi object
secretGenerator:               # (4) tạo object Secret từ file .env
  - name: orders-db
    envs: [secrets/orders-db.env]
images:                        # (5) tìm "image: retail-store/orders" và thay thế
  - name: retail-store/orders
    newName: ghcr.io/dwchwang/retail-store-orders
    newTag: "0.1.0"
```

Đầu vào và đầu ra của Kustomize, xem bằng `kubectl kustomize k8s`:

| Bạn viết | Kustomize render ra |
|---|---|
| `metadata: {name: orders}` | `metadata: {name: orders, namespace: retail-store, labels: {app.kubernetes.io/part-of: retail-store}}` |
| `image: retail-store/orders` | `image: ghcr.io/dwchwang/retail-store-orders:0.1.0` |
| `secretKeyRef: {name: orders-db}` | `secretKeyRef: {name: orders-db-<hash>}` |
| File `secrets/orders-db.env`: `password=abc` | `kind: Secret`, `data: {password: YWJj}` (base64) |

Vì có bước render này, file gốc dùng tên image "giả" `retail-store/orders`: đổi registry hay tag chỉ cần sửa một chỗ trong `kustomization.yaml`. Lệnh `kubectl kustomize k8s` có in Secret ra màn hình (base64, giải mã được), nên **đừng dán output đó lên đâu**.

> **Lỗi đang có trong file của bạn:** dòng 1 của `k8s/kustomization.yaml` là `namespace.yamlapiVersion: ...`. Chữ `namespace.yaml` bị dính vào lúc paste. Xoá chữ đó để dòng 1 còn `apiVersion: kustomize.config.k8s.io/v1beta1`. Lỗi hiện ra sẽ là `json: unknown field "namespace.yamlapiVersion"`. Tôi đã render thử một bản sao đã sửa dòng đó: các file còn lại hợp lệ, ra đúng 30 object (1 Namespace, 3 Secret, 5 ConfigMap, 10 Service, 6 Deployment, 4 StatefulSet, 1 Ingress) với image trỏ đúng GHCR.

---

## 9. Tự viết một manifest mới: quy trình

Không ai gõ YAML K8s từ trí nhớ. Quy trình thực tế:

**1. Sinh khung bằng `kubectl create --dry-run`:**
```bash
kubectl create deployment demo --image=nginx:1.27 --port=80 --dry-run=client -o yaml
kubectl create service clusterip demo --tcp=80:80 --dry-run=client -o yaml
kubectl create configmap demo --from-literal=KEY=value --dry-run=client -o yaml
kubectl create ingress demo --class=traefik --rule="/*=demo:80" --dry-run=client -o yaml
```
Lệnh in ra YAML đúng chuẩn mà không tạo gì. Chép vào file rồi sửa tiếp.

**2. Tra trường cần thêm:** `kubectl explain deployment.spec.template.spec.containers.resources`.

**3. Kiểm tra trước khi apply:**
```bash
kubectl apply -k k8s --dry-run=client   # kiểm tra cú pháp YAML phía máy bạn
kubectl apply -k k8s --dry-run=server   # API server kiểm tra schema, không tạo gì
kubectl diff -k k8s                     # so với những gì đang chạy (giống terraform plan)
```

**4. Học từ object đang chạy:** `kubectl -n kube-system get ds rke2-traefik -o yaml` xem RKE2 viết Traefik thế nào. Bỏ qua phần `status`, `managedFields`, `uid`, `resourceVersion` vì K8s tự sinh.

**5. Tài liệu chính thức:** kubernetes.io/docs → mục *Concepts* có ví dụ YAML cho từng kind. Đây là tài liệu chung cho mọi cluster, không riêng RKE2.

---

## 10. Bảng tra nhanh: trường nào nằm ở đâu

| Muốn | Viết ở | Kind |
|---|---|---|
| Số bản chạy | `spec.replicas` | Deployment/StatefulSet |
| Image, port, env | `spec.template.spec.containers[]` | Deployment/StatefulSet |
| Ổ đĩa bền cho từng pod | `spec.volumeClaimTemplates[]` | StatefulSet |
| Ổ tạm / gắn ConfigMap thành file | `spec.template.spec.volumes[]` | Deployment/StatefulSet |
| Gắn volume vào đường dẫn | `containers[].volumeMounts[]` | (trong pod) |
| Chạy non-root | `spec.template.spec.securityContext` | (trong pod) |
| Tên DNS nội bộ | `metadata.name` | Service |
| Chọn pod nhận traffic | `spec.selector` | Service |
| Mở ra internet theo path/domain | `spec.rules[]` | Ingress |
| Cấu hình | `data` | ConfigMap |
| Password | `secretGenerator` | kustomization.yaml |
| Đổi image/tag | `images[]` | kustomization.yaml |

---

## 11. Bài tập tự kiểm tra (làm trên cluster rồi sửa lại)
1. Đổi `selector` của Service `catalog` thành `app: catalogx`, apply, chạy `kubectl -n retail-store get endpoints catalog`, rồi mở UI xem chuyện gì xảy ra.
2. Xoá dấu ngoặc kép ở `"true"` trong ConfigMap `cart`, chạy `kubectl apply -k k8s --dry-run=server` và đọc thông báo lỗi.
3. Chạy `kubectl explain statefulset.spec.persistentVolumeClaimRetentionPolicy` để xem cách cấu hình cho PVC tự xoá theo StatefulSet.
4. Sinh khung Deployment bằng `kubectl create deployment ... --dry-run=client -o yaml` rồi so với `apps/catalog.yaml`: đánh dấu những trường bạn đã thêm vào và giải thích vì sao.

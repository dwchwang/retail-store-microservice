# GĐ3 – Hiểu Kubernetes qua dự án

> Đọc cùng guide thực hành [gd3-01-k8s-manifests.md](../guides/gd3-01-k8s-manifests.md). File này giải thích **từng thứ trong guide là gì, vì sao làm vậy, và nó chạy bên trong K8s ra sao**.

## 1. Bức tranh tổng thể

### 1.1 Từ docker-compose sang Kubernetes

Ở GĐ1 bạn đã chạy toàn bộ app bằng compose trên **1 máy**. GĐ3 chạy cùng app đó trên **cluster 3 máy**. Gần như mọi khái niệm của compose đều có bản tương ứng trong K8s:

| docker-compose (GĐ1) | Kubernetes (GĐ3) | Khác biệt chính |
|---|---|---|
| `services.ui` | **Deployment** `ui` + **Service** `ui` | Chạy bao nhiêu bản (Deployment) và cách gọi tới (Service) được tách thành 2 object |
| `services.orders-db` + `volumes:` | **StatefulSet** + **PVC** | Volume nằm trên Longhorn, không nằm trên ổ của một máy cụ thể |
| `environment:` | **ConfigMap** | Cấu hình tách khỏi file định nghĩa app |
| `.env` (password) | **Secret** | Có phân quyền đọc riêng |
| `healthcheck:` | **readiness/liveness/startup probe** | 3 loại probe với 3 mục đích khác nhau |
| `depends_on: service_healthy` | *(không có)* | K8s cứ restart cho tới khi dependency sẵn sàng (xem §10) |
| `mem_limit` | `resources.limits.memory` | Có thêm `requests` để scheduler chọn node |
| `read_only`, `user:` | `securityContext` | |
| Nginx publish `8080:80` | **Ingress** + Traefik | |
| Network `backend` / `frontend` | **Namespace** + (Phần 3) NetworkPolicy | Mặc định mọi pod đều gọi được nhau |
| `restart: unless-stopped` | Có sẵn | Controller tự tạo lại pod chết, kể cả khi node chết |
| `docker compose up -d` | `kubectl apply -k k8s` | |

**Điều compose không làm được:** khi một máy chết, K8s tự chuyển pod sang máy khác, còn Longhorn giữ bản sao dữ liệu trên các node khác. Đó là lý do công ty dùng K8s.

### 1.2 Một request đi qua những gì

```
Trình duyệt
   │  http://<EIP>/
   ▼
EIP → server-1 :80                       (Security Group mở 80 public)
   │
   ▼
Traefik pod (hostPort 80)                ← Ingress Controller, RKE2 cài sẵn
   │  đọc Ingress "ui": path / → service ui:8080
   ▼
Service ui (ClusterIP 10.43.x.x:8080)    ← IP ảo, kube-proxy chia tải
   │
   ▼
Pod ui (10.42.x.x:8080)                  ← có thể nằm trên node bất kỳ
   │  gọi http://catalog:8080            ← CoreDNS phân giải tên Service
   ▼
Service catalog → Pod catalog
   │  catalog-db:3306                    ← headless Service, trỏ thẳng IP pod
   ▼
Pod catalog-db-0 → PVC → Longhorn volume (3 bản sao trên 3 node)
```

Nhớ 2 dải IP:
- `10.42.0.0/16`: **IP của pod**. Do CNI (Canal) cấp, và đổi mỗi khi pod được tạo lại.
- `10.43.0.0/16`: **IP của Service**. Cố định suốt vòng đời Service. Lỗi `10.43.0.1:443 i/o timeout` ở GĐ2 chính là pod không gọi được Service `kubernetes`.

---

## 2. Mô hình hoạt động: khai báo và vòng lặp reconcile

K8s là hệ thống **declarative**: bạn mô tả **trạng thái mong muốn**, các controller liên tục kéo trạng thái thật về đúng như vậy.

```
kubectl apply ──▶ API server ──▶ etcd (lưu "muốn có gì")
                                   │
         ┌─────────────────────────┘ controller theo dõi
         ▼
Deployment controller: "muốn 1 pod ui, đang có 0" → tạo pod
Scheduler: "pod này xin 384Mi RAM, node nào còn chỗ?" → chọn agent-1
kubelet trên agent-1: kéo image, chạy container, chạy probe
```

Khi bạn `kubectl delete pod orders-db-0`, StatefulSet controller thấy "muốn 1, có 0" nên tạo lại ngay. Bài DoD "xoá pod DB" kiểm tra chính vòng lặp này.

Tư duy này giống Terraform (code ↔ state ↔ thực tế). Khác ở chỗ Terraform chỉ so sánh khi bạn gõ `plan`, còn K8s so sánh **liên tục**.

### Label và selector: cách các object tìm thấy nhau

K8s **không** nối các object bằng tên, mà bằng **label**:

```yaml
# Deployment                        # Service
selector:                           selector:
  matchLabels: {app: ui}  ◀──┐        app: ui   ──┐
template:                    │                    │
  metadata:                  │   cùng label       │
    labels: {app: ui}  ──────┴────────────────────┘
```
- Deployment quản lý mọi pod có `app: ui`.
- Service gửi traffic tới mọi pod có `app: ui` **và đang Ready**.
- Gõ sai label thì pod vẫn chạy, nhưng Service không có endpoint (`kubectl get endpoints ui` trống).

---

## 3. Image và registry

### 3.1 Vì sao cần registry
Ở GĐ1, `docker compose build` tạo image ngay trên máy chạy nó. Trong K8s, **kubelet trên từng node tự kéo image**, và nó không đọc được image trên laptop của bạn. Vì vậy phải đẩy image lên một registry mà mọi node đều truy cập được.

### 3.2 Kiến trúc CPU: arm64 và amd64
Image chứa binary đã biên dịch cho một kiến trúc CPU cụ thể. Mac M-series dùng `arm64`, EC2 t3 dùng `amd64`. Image build cho arm64 mà chạy trên amd64 sẽ lỗi `exec format error`.

**Mẹo `--platform=$BUILDPLATFORM`:**
```
Stage build  (chạy bằng arm64 gốc, nhanh)   →  tạo ra file .jar / binary Go cho amd64
Stage runtime (amd64)                         →  chỉ COPY file vào, không chạy gì nặng
```
- `.jar` là bytecode Java, chạy trên mọi kiến trúc, nên build ở đâu cũng được.
- Go cross-compile được: `GOARCH=$TARGETARCH` sinh binary amd64 ngay trên máy arm64.
- Node thì không: một số package npm có **native module** (code C++), phải biên dịch đúng kiến trúc đích. Vì vậy checkout giữ nguyên.

### 3.3 Tag
- `latest` không cho biết đang chạy bản nào. Nó cũng làm kubelet không chắc có cần kéo lại image hay không.
- Tag cố định (`0.1.0`, sau này là git SHA) giúp **rollback bằng cách đổi lại tag cũ**, và mỗi lần deploy đều truy vết được.

### 3.4 Public và private
Package GHCR để public thì node kéo image không cần đăng nhập. Ở công ty, image để private: tạo Secret kiểu `docker-registry` rồi khai `imagePullSecrets` trong pod (làm ở Phần 3).

---

## 4. Kustomize

Kustomize là công cụ **ghép và biến đổi YAML** mà không cần template. Nó có sẵn trong `kubectl` (`-k`).

| Trường trong `kustomization.yaml` | Tác dụng |
|---|---|
| `resources:` | Danh sách file cần gom lại |
| `namespace: retail-store` | Gắn namespace cho **mọi** object, nên các file con không phải ghi lại |
| `labels:` | Gắn label `part-of` cho mọi object (không đụng vào selector) |
| `secretGenerator:` | Sinh Secret từ file `.env` |
| `images:` | Thay `retail-store/ui` bằng `ghcr.io/dwchwang/retail-store-ui:0.1.0` |

**Xem trước kết quả:** `kubectl kustomize k8s`. Đây là YAML cuối cùng thực sự được gửi lên API server. Khi debug, hãy đọc bản này chứ không đọc file gốc.

### Hash suffix của secretGenerator
Secret được tạo ra sẽ có tên dạng `orders-db-7t5k2m9h4c`, trong đó phần đuôi là **hash của nội dung**. Kustomize tự sửa mọi `secretKeyRef: name: orders-db` thành tên có hash đó.

Vì sao làm vậy: pod chỉ đọc biến môi trường **lúc khởi động**. Nếu chỉ sửa nội dung Secret thì pod đang chạy vẫn dùng password cũ. Khi tên Secret đổi, pod template cũng đổi, nên Deployment **tự rollout** pod mới.

> ConfigMap trong guide viết tay, nên **không** có hash. Sửa ConfigMap xong phải chạy `kubectl -n retail-store rollout restart deploy/<app>` thì app mới nhận giá trị mới.

### Kustomize và Helm (Phần 2)
| | Kustomize | Helm |
|---|---|---|
| Cách làm | YAML thật + "vá" lên trên | Template có `{{ .Values.x }}` |
| Ưu điểm | Đơn giản, đọc là hiểu | Đóng gói, chia sẻ, versioning, rollback, có điều kiện và vòng lặp |
| Thường dùng | Biến thể theo môi trường (dev/prod) | Phân phối phần mềm (Longhorn, Traefik đều là chart) |

Ở công ty hai công cụ thường dùng chung. ArgoCD (GĐ4) hỗ trợ cả hai.

---

## 5. Workload: Pod, Deployment, StatefulSet

### 5.1 Pod
Pod là đơn vị nhỏ nhất. Nó gồm 1 hoặc nhiều container dùng chung IP và volume. Pod **có thể bị xoá bất cứ lúc nào** (node chết, rollout, bị evict), nên không bao giờ tạo pod trực tiếp mà luôn tạo qua controller.

### 5.2 Deployment
```
Deployment ui  ──quản lý──▶  ReplicaSet ui-7f9c (tag 0.1.0)  ──▶  Pod ui-7f9c-xk2
```
Khi đổi image sang `0.2.0`, Deployment tạo ReplicaSet mới, rồi **rolling update**: bật pod mới lên, chờ nó Ready, sau đó mới tắt pod cũ. Nhờ readinessProbe nên deploy không bị downtime. `kubectl rollout undo deploy/ui` quay về ReplicaSet trước.

Các pod trong Deployment **giống hệt nhau và thay thế được cho nhau**, nên phù hợp với app **stateless** (5 app của dự án).

### 5.3 StatefulSet
Dùng cho thứ có **danh tính và dữ liệu riêng** (DB, queue):

| | Deployment | StatefulSet |
|---|---|---|
| Tên pod | Ngẫu nhiên | Cố định: `orders-db-0`, `-1`… |
| PVC | Các pod dùng chung một PVC, hoặc không có | `volumeClaimTemplates`: **mỗi pod một PVC riêng**, tên `data-orders-db-0` |
| Pod tạo lại | Tên mới, có thể không có dữ liệu | **Cùng tên, gắn lại đúng PVC cũ** |
| Thứ tự | Song song | Lần lượt `-0` rồi `-1`; tắt theo thứ tự ngược lại |
| DNS | Qua IP ảo của Service | Mỗi pod có DNS riêng: `orders-db-0.orders-db` |

Với `replicas: 1` như dự án thì khác biệt quan trọng nhất là **PVC đi theo tên pod**. Thứ tự và DNS từng pod chỉ quan trọng khi chạy cluster DB nhiều bản (primary/replica), vì các bản cần gọi nhau bằng tên cố định.

### 5.4 Vì sao Redis dùng Deployment
Redis ở đây chỉ giữ session checkout tạm thời (`--save "" --appendonly no` tắt ghi đĩa). Mất dữ liệu thì người dùng chỉ phải bấm checkout lại. Không cần dữ liệu bền thì không cần StatefulSet hay PVC: dùng Deployment + `emptyDir` cho đơn giản và nhẹ.

> Ở production, chạy DB trong K8s là quyết định gây tranh cãi. Nhiều công ty để DB ngoài cluster (VM riêng hoặc managed). Khi chạy trong K8s thì họ dùng **Operator** (CloudNativePG, MariaDB Operator) để lo backup, failover, nâng cấp. Dự án viết StatefulSet tay để hiểu nền tảng.

---

## 6. Networking: Service, DNS, Ingress

### 6.1 Các loại Service
| Loại | Cách hoạt động | Dùng ở đâu |
|---|---|---|
| **ClusterIP** (mặc định) | 1 IP ảo cố định, kube-proxy chia tải tới các pod Ready | 5 app, Redis |
| **Headless** (`clusterIP: None`) | Không có IP ảo; DNS trả về **thẳng IP của pod** | 4 StatefulSet DB |
| **NodePort** | Mở port 30000–32767 trên **mọi node** | Phương án dự phòng khi Traefik không có hostPort |
| **LoadBalancer** | Nhờ cloud tạo load balancer | Trên EKS sẽ tạo ELB. Trên RKE2 tự dựng không có cloud controller, nên **`<pending>` mãi** |

StatefulSet bắt buộc có headless Service (`serviceName:`) để sinh DNS cho từng pod.

### 6.2 DNS nội bộ
CoreDNS cấp tên cho mọi Service theo dạng:
```
<service>.<namespace>.svc.cluster.local
orders-db.retail-store.svc.cluster.local
```
Pod ở cùng namespace chỉ cần gọi `orders-db`, vì file `/etc/resolv.conf` của pod có sẵn search domain. Đây là lý do ConfigMap ghi `catalog-db:3306` giống hệt compose: tên Service đóng vai trò tên container trong compose.

### 6.3 Ba loại port
```yaml
# Service                          # Pod
ports:                             ports:
  - port: 8080        ← client gọi    - name: http
    targetPort: http  ← tên port ──▶    containerPort: 8080  ← app nghe thật
```
Dùng **tên port** (`http`) thay vì số: sau này app đổi port thì chỉ sửa ở pod, Service vẫn đúng.

### 6.4 Ingress và Ingress Controller
- **Ingress** chỉ là một **luật** (path `/` → service `ui`). Bản thân nó không xử lý traffic.
- **Ingress Controller** là pod thật đọc các luật đó và làm reverse proxy. Nó đóng vai trò Nginx ở GĐ1. RKE2 v1.36 cài sẵn **Traefik**.
- **IngressClass** (`ingressClassName: traefik`) cho biết controller nào xử lý luật này, phòng trường hợp cluster có nhiều controller.

**Traffic từ internet vào Traefik bằng cách nào?** RKE2 chạy Traefik dạng **DaemonSet** (mỗi node một pod) với **`hostPort: 80/443`**: port 80 của chính node EC2 được chuyển thẳng vào pod Traefik. Vì vậy `http://<EIP>/` đi tới được Traefik trên server-1. Nếu Traefik chỉ có Service `LoadBalancer` thì sẽ kẹt `<pending>` (xem §6.1), và guide có phương án dự phòng.

Ở công ty on-prem, phía trước thường có thêm một load balancer phần cứng, HAProxy, hoặc MetalLB cấp IP cho Service `LoadBalancer`.

---

## 7. ConfigMap và Secret

| | ConfigMap | Secret |
|---|---|---|
| Chứa | Endpoint, provider, cờ bật/tắt | Password, token |
| Lưu | Plain text | **base64**: chỉ là mã hoá ký tự, **không phải mã hoá bảo mật** |
| Bảo vệ | | Phân quyền RBAC riêng; có thể bật encryption at rest trong etcd |

Hai cách đưa vào container:
- `envFrom: configMapRef`: lấy **toàn bộ** key thành biến môi trường. Tiện cho cấu hình.
- `env: valueFrom: secretKeyRef`: lấy **đúng một key**. Mỗi app chỉ nhận đúng password nó cần (nguyên tắc least privilege): catalog không đọc được password của orders.

**Vì sao không commit Secret YAML?** `echo <base64> | base64 -d` là ra password. Guide giữ password trong `k8s/secrets/*.env` (bị gitignore) và để Kustomize sinh Secret lúc apply. GĐ4 sẽ dùng **Sealed Secrets**: mã hoá bằng public key của cluster, chỉ cluster giải mã được, nên commit an toàn.

---

## 8. Storage: PV, PVC, StorageClass

### 8.1 Ba khái niệm
```
PVC (Pod xin: "cho tôi 2Gi, ReadWriteOnce")
  │  bind
  ▼
PV  (ổ đĩa thật: Longhorn volume pvc-3f2a…)
  ▲  tự tạo (dynamic provisioning)
  │
StorageClass longhorn (default) — "ai xin thì Longhorn tạo volume"
```
- **PVC** là *yêu cầu* (ví như phiếu thuê ổ đĩa). Thuộc namespace.
- **PV** là *ổ đĩa thật*. Thuộc cả cluster.
- **StorageClass** là *nhà cung cấp*. Do Longhorn là default (GĐ2 đã đặt), PVC không cần ghi `storageClassName`.

### 8.2 PVC được bind thế nào (câu hỏi DoD)
1. StatefulSet tạo PVC `data-orders-db-0` từ `volumeClaimTemplates`.
2. PVC ở trạng thái `Pending`. Longhorn provisioner thấy PVC dùng StorageClass của nó, tạo volume 2Gi và một PV tương ứng.
3. K8s **bind** PVC với PV (quan hệ 1-1). PVC chuyển sang `Bound`.
4. Scheduler đặt pod lên một node. Longhorn **attach** volume vào node đó (qua iSCSI, lý do GĐ2 cài `open-iscsi`), format ext4, mount vào container.
5. Pod chết và được tạo lại, kể cả trên node khác: Longhorn detach khỏi node cũ, attach vào node mới. Dữ liệu đi theo.

### 8.3 Longhorn replica
Mỗi volume có 3 bản sao trên 3 node (mặc định). Node chứa pod chết thì dữ liệu vẫn còn trên 2 node kia. Đổi lại, mỗi lần ghi phải đi qua mạng tới các replica, nên chậm hơn ổ local.

### 8.4 Access mode
- **ReadWriteOnce (RWO):** chỉ một node mount tại một thời điểm. Đủ cho DB vì chỉ có một pod.
- **ReadWriteMany (RWX):** nhiều node cùng mount. Longhorn làm được qua NFS (lý do GĐ2 cài `nfs-common`), nhưng DB không cần.

### 8.5 Bẫy `lost+found`
Ổ ext4 mới format luôn có thư mục `lost+found` ở gốc. Entrypoint của Postgres và MariaDB thấy thư mục data không trống thì từ chối `initdb`. Hai cách xử lý:
- `PGDATA=/var/lib/postgresql/data/pgdata`: bảo Postgres dùng thư mục con.
- `subPath: mysql`: chỉ mount thư mục con `mysql/` của volume vào `/var/lib/mysql`.

### 8.6 Vòng đời dữ liệu
| Hành động | PVC/dữ liệu |
|---|---|
| Xoá pod | **Còn** (DoD kiểm tra điều này) |
| Xoá StatefulSet | **Còn**. K8s cố tình không xoá PVC để tránh mất dữ liệu |
| Xoá namespace / `kubectl delete -k k8s` | **Mất**: PVC bị xoá, reclaim policy `Delete` của Longhorn xoá luôn volume |
| `terraform destroy` | **Mất**: ổ EBS chứa Longhorn bị xoá |

Đây là lý do Phần 3 cần **backup lên S3**: dữ liệu phải sống được cả khi cluster mất.

### 8.7 emptyDir
Thư mục tạm, sống cùng pod: container restart thì còn, pod bị xoá thì mất. Guide dùng cho `/tmp` của app và `/data` của Redis.

---

## 9. Probe

### 9.1 Ba loại probe
| Probe | Câu hỏi | Fail thì sao | Dùng khi |
|---|---|---|---|
| **startupProbe** | "Khởi động xong chưa?" | Hết `failureThreshold` → restart. **Trong lúc chạy, 2 probe kia bị tạm dừng** | App khởi động chậm (JVM) |
| **readinessProbe** | "Nhận traffic được chưa?" | Bị **gỡ khỏi Service endpoints**, không restart | Mọi app |
| **livenessProbe** | "Còn sống không, hay treo rồi?" | **Restart container** | Mọi app |

### 9.2 Readiness và liveness khác nhau thế nào (câu hỏi DoD)
- **Readiness fail** nghĩa là "tạm thời chưa phục vụ được" (đang khởi động, đang quá tải, mất kết nối DB). K8s chỉ **ngừng gửi request**. Khi probe pass lại thì pod tự nhận traffic trở lại.
- **Liveness fail** nghĩa là "hỏng hẳn, không tự hồi phục" (deadlock, treo). K8s **giết và chạy lại** container.

**Quy tắc quan trọng:** liveness **không được** phụ thuộc vào thứ bên ngoài như DB. Nếu DB chậm 30 giây mà liveness của cả 3 app Java kiểm tra DB, cả 3 sẽ bị restart cùng lúc dù chúng không hỏng, khiến sự cố lan rộng hơn. Spring Boot tách sẵn 2 endpoint: `/actuator/health/liveness` chỉ kiểm tra trạng thái nội bộ của app, `/actuator/health/readiness` cho biết app sẵn sàng nhận request.

### 9.3 Tính thời gian
```yaml
startupProbe:
  periodSeconds: 5
  failureThreshold: 36     # 5s × 36 = 180s: app có tối đa 3 phút để khởi động
```
Không có startupProbe thì phải đặt `initialDelaySeconds` của liveness thật lớn. Như vậy pod nào treo thật cũng phải chờ lâu mới bị phát hiện. startupProbe tách hai việc đó ra.

### 9.4 Ba cách kiểm tra
| Cách | Ví dụ trong guide |
|---|---|
| `httpGet` | 5 app: gọi `/health`, `/actuator/health/*`. Mã 200–399 là pass |
| `exec` | DB: chạy `pg_isready`, `healthcheck.sh`, `redis-cli ping`. Exit code 0 là pass |
| `tcpSocket` | DynamoDB Local: chỉ cần mở được kết nối tới port 8000 (image không có công cụ kiểm tra) |

---

## 10. Thứ tự khởi động: K8s không có `depends_on`

Compose có `depends_on: condition: service_healthy`. K8s cố tình không có cơ chế này, vì trong hệ phân tán dependency có thể chết **bất cứ lúc nào**, không chỉ lúc khởi động. App phải tự chịu được việc đó.

Thực tế khi `apply` lần đầu:
```
0s    tất cả pod cùng start
20s   orders kết nối Postgres chưa được → crash → restart (RESTARTS=1)
40s   Postgres Ready → orders start lại thành công
```
`CrashLoopBackOff` có backoff tăng dần (10s, 20s, 40s… tối đa 5 phút), nên cluster tự hội tụ. Vì vậy guide nói "restart 1–2 lần lúc đầu là bình thường".

Cách làm sạch hơn: thêm **initContainer** chờ DB mở port rồi mới chạy app. Chỉ nên dùng khi app crash quá ồn ào, vì nó chỉ giúp lúc khởi động.

---

## 11. Resources: requests và limits

| | requests | limits |
|---|---|---|
| Ý nghĩa | "Tôi cần ít nhất chừng này" | "Không được vượt quá chừng này" |
| Ai dùng | **Scheduler**: chỉ đặt pod lên node còn đủ requests chưa cấp | **Kernel** (cgroup) thực thi |
| Vượt quá | Được, nếu node còn trống | RAM: **OOMKilled**. CPU: bị **throttle** (làm chậm) |

### 11.1 Vì sao không đặt limit CPU
CPU là tài nguyên **nén được**: thiếu thì chạy chậm chứ không chết. Có limit CPU thì kernel dùng CFS quota: dùng hết quota trong chu kỳ 100ms là bị dừng tới chu kỳ sau, **dù node đang rảnh**. JVM khởi động cần burst CPU rất mạnh (JIT, nạp class), nên limit CPU làm thời gian khởi động tăng gấp nhiều lần và startupProbe hết hạn. Chỉ đặt `requests.cpu` thì pod vẫn được chia CPU công bằng khi node bận, và dùng hết CPU khi node rảnh.

RAM thì **không nén được**: thiếu là chết. Nên luôn đặt limit RAM để một app bị leak không kéo sập cả node.

### 11.2 JVM và memory limit
`-XX:MaxRAMPercentage=75.0` (đặt trong Dockerfile) cho JVM đọc limit của container: 768Mi × 75% ≈ **576Mi heap**. Phần còn lại dành cho metaspace, thread stack và bộ nhớ ngoài heap. Đặt 100% thì JVM sẽ vượt limit và bị OOMKilled.

### 11.3 QoS class
| Class | Điều kiện | Bị đuổi khi node thiếu RAM |
|---|---|---|
| Guaranteed | requests = limits cho cả CPU và RAM | Cuối cùng |
| **Burstable** | Có requests, khác limits | Ở giữa (pod của dự án thuộc loại này) |
| BestEffort | Không khai gì | Đầu tiên |

### 11.4 Sizing có đủ không?
Tổng requests RAM của app và data khoảng 2,3 GiB (5 data store ≈ 1056Mi, 5 app ≈ 1344Mi), chia cho 3 node (8 + 4 + 4 GiB, trừ phần RKE2 và Longhorn). Còn dư cho monitoring ở GĐ5. `kubectl describe node <node>` (phần *Allocated resources*) cho biết node đã cấp bao nhiêu.

---

## 12. securityContext

Hai cấp:
- **Pod** (`spec.securityContext`): áp dụng cho mọi container (`runAsUser`, `runAsNonRoot`, `seccompProfile`).
- **Container** (`containers[].securityContext`): riêng từng container (`readOnlyRootFilesystem`, `capabilities`, `allowPrivilegeEscalation`).

| Thiết lập | Chống lại điều gì |
|---|---|
| `runAsNonRoot: true` | Kẻ tấn công chiếm được app thì không có quyền root trong container (thoát ra node khó hơn nhiều) |
| `runAsUser: 1000` (số) | kubelet cần **UID dạng số** để kiểm tra non-root. Image khai `USER app` bằng tên thì kubelet không biết `app` là UID nào, nên báo lỗi `CreateContainerConfigError` |
| `readOnlyRootFilesystem` | Không ghi được malware hay sửa binary trong container. Chỗ nào cần ghi thì mount `emptyDir` |
| `capabilities: drop: [ALL]` | Bỏ các quyền đặc biệt của Linux (đổi owner file, raw socket, bind port < 1024…). App nghe 8080 nên không cần |
| `allowPrivilegeEscalation: false` | Chặn leo quyền qua binary setuid như `sudo` |
| `seccompProfile: RuntimeDefault` | Chặn các syscall nguy hiểm mà app bình thường không dùng |

Bộ thiết lập này tương ứng mức **"restricted"** của *Pod Security Standards*. Ở công ty, namespace thường được gắn label để admission controller **từ chối** pod không đạt chuẩn.

**Ngoại lệ trong guide:** 4 image DB chính thức (MariaDB, Postgres, RabbitMQ, DynamoDB Local) khởi động bằng root để `chown` thư mục data rồi mới hạ quyền (riêng DynamoDB Local thì guide phải đặt `runAsUser: 0` để ghi được vào volume). Đây là đánh đổi chấp nhận được khi dùng image có sẵn. Muốn chặt hơn thì dùng image Bitnami (non-root sẵn) hoặc `fsGroup`.

---

## 13. Pod gặp lỗi: đọc trạng thái

```
Pending ──▶ ContainerCreating ──▶ Running (READY 0/1) ──▶ Running (READY 1/1)
   │               │                     │
   │               │                     └─ readiness chưa pass
   │               └─ kéo image, mount volume, gắn Secret
   └─ scheduler chưa tìm được node (thiếu RAM, PVC chưa Bound)
```

| Trạng thái | Xem ở đâu | Ý nghĩa |
|---|---|---|
| `Pending` | `describe pod` → Events | Không node nào đủ requests, hoặc PVC chưa Bound |
| `ImagePullBackOff` | `describe pod` | Sai tên/tag, image private, sai kiến trúc |
| `CreateContainerConfigError` | `describe pod` | Thiếu Secret/ConfigMap, hoặc UID không phải số |
| `CrashLoopBackOff` | `logs --previous` | App start rồi chết. Log của **lần trước** mới cho biết lý do |
| `OOMKilled` | `describe pod` → Last State | Vượt limit RAM |
| Running nhưng `0/1` | `describe pod` | Readiness fail, Service không gửi traffic tới |

**Thứ tự điều tra:** `get` (thấy triệu chứng) → `describe` (Events: K8s đã làm gì) → `logs` (app nói gì) → `exec` (vào xem tận nơi).

---

## 14. Trả lời các câu hỏi DoD

**StatefulSet và Deployment khác nhau thế nào?**
Deployment coi các pod là giống nhau và thay thế được, nên hợp với app stateless. StatefulSet cho mỗi pod một danh tính cố định (tên, DNS) và **một PVC riêng đi theo tên đó**, nên pod tạo lại vẫn gắn đúng dữ liệu cũ. Dùng cho DB và queue. Xem §5.3.

**Readiness và liveness khác nhau thế nào?**
Readiness fail thì pod bị gỡ khỏi Service (không nhận traffic) nhưng vẫn chạy. Liveness fail thì container bị restart. Liveness không được phụ thuộc DB, nếu không một sự cố DB sẽ làm mọi app restart theo. Xem §9.2.

**PVC được bind ra sao?**
PVC xin dung lượng → StorageClass mặc định (Longhorn) tự tạo PV → K8s bind 1-1 → Longhorn attach volume vào node có pod qua iSCSI. Xem §8.2.

---

## 15. Mapping với nguyên tắc dự án

| Nguyên tắc (`devops_learning.md`) | Thể hiện trong GĐ3 |
|---|---|
| Mọi thứ là code | Toàn bộ app nằm trong `k8s/`, một lệnh `kubectl apply -k` là dựng lại. Không `kubectl edit` tay trên cluster |
| Dựng lại được bất cứ lúc nào | `terraform apply` → `ansible-playbook` → `kubectl apply -k k8s`. Image đã nằm trên GHCR |
| Không lộ secret | Password sinh ngẫu nhiên, nằm trong `.env` bị gitignore; Secret chỉ tồn tại trong cluster |
| Không chạy root | securityContext restricted cho 5 app; DB là ngoại lệ có lý do |
| Mọi DB chạy bằng StatefulSet | 4 StatefulSet trên Longhorn; Redis là ngoại lệ vì không cần lưu |
| Kiểm soát chi phí | Không dùng ELB hay EBS CSI; GHCR miễn phí; destroy cuối buổi |

---

## 16. Thứ tự thực hành gợi ý
1. Dựng cluster, xem Traefik được expose thế nào (`kubectl -n kube-system get ds -o wide`).
2. Build và push image. Kiểm tra kiến trúc bằng `docker manifest inspect`.
3. `kubectl kustomize k8s | less`: đọc YAML cuối cùng, tìm tên Secret có hash và tên image đã được thay.
4. Apply **data stores trước**, chờ Ready, xem PVC và volume trên Longhorn UI (`kubectl -n longhorn-system port-forward svc/longhorn-frontend 8000:80`).
5. Apply apps, theo dõi `get pods -w` để thấy restart rồi tự hội tụ.
6. Smoke test qua Ingress, đặt hàng, xem bảng `orders` trong Postgres.
7. Thử phá: xoá pod DB; sửa sai label của Service rồi xem `get endpoints`; giảm limit RAM của ui xuống 256Mi để thấy OOMKilled. Sửa lại sau mỗi lần thử.
8. `terraform destroy`.

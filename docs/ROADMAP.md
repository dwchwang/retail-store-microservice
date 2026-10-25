# Roadmap triển khai chi tiết

> Kiến trúc: xem [ARCHITECTURE.md](ARCHITECTURE.md). Bối cảnh và nguyên tắc: xem [../devops_learning.md](../devops_learning.md).
> Đánh dấu `[x]` khi xong. Mỗi giai đoạn chỉ coi là xong khi đạt **Definition of Done (DoD)**.

## Cấu trúc repo đề xuất

```
retail-store/                  # repo chính (app + infra)
├── src/                       # code 5 service lấy từ upstream (không sửa logic)
├── docker/
│   ├── docker-compose.yml
│   ├── nginx/nginx.conf
│   └── .env.example           # .env thật KHÔNG commit
├── infra/
│   ├── terraform/             # GĐ2
│   └── ansible/               # GĐ2
├── charts/retail-store/       # GĐ3 – Helm chart tự viết
├── Jenkinsfile                # GĐ4
└── docs/                      # kiến trúc, runbook, nhật ký lỗi

retail-store-gitops/           # repo riêng cho ArgoCD (GĐ4)
```

---

## GĐ 0 – Chuẩn bị
- [x] Clone upstream, copy `src/` (đã xoá Helm chart; giữ Dockerfile/compose gốc để tham khảo)
- [ ] `git init`, tạo `.gitignore` (`.env`, `*.tfstate*`, `.terraform/`, `target/`, `node_modules/`)
- [ ] Push lên GitHub (repo private hoặc public)
- [ ] Cài local: Docker Desktop, `kubectl`, `helm`, `terraform`, `ansible`, `awscli`

**DoD:** repo có `src/` + `docs/`, commit đầu tiên đã push.

---

## GĐ 1 – Docker ✅

### 1.1 Dockerfile multi-stage (thứ tự từ dễ đến khó)
- [x] **catalog** (Go): build stage `golang` → runtime `distroless`/`alpine`, binary tĩnh (`CGO_ENABLED=0`)
- [x] **checkout** (Node): stage cài deps + build TS → runtime chỉ có `dist/` + prod deps
- [x] **cart / orders / ui** (Java): build bằng Maven → runtime JRE 21 (không phải JDK). Tận dụng layer cache cho `pom.xml`
- [x] Mọi image: chạy **non-root**, có `.dockerignore`, pin version base image, có `HEALTHCHECK` hoặc để compose kiểm tra
- [x] So sánh kích thước image trước và sau multi-stage (`docker images`)

### 1.2 docker-compose
- [x] 5 data store: MariaDB, DynamoDB Local, Postgres, RabbitMQ, Redis. Có volume cho những store cần giữ dữ liệu
- [x] 5 app service, biến môi trường lấy theo ARCHITECTURE.md §4
- [x] Secret đưa vào qua file `.env` (có `.env.example` commit kèm)
- [x] `healthcheck` + `depends_on: condition: service_healthy`
- [x] Network: tách `frontend` (nginx, ui) và `backend` (còn lại); chỉ nginx publish port
- [x] `mem_limit`, `restart: unless-stopped`, `read_only` + `tmpfs` ở service nào làm được

### 1.3 Nginx reverse proxy
- [x] Nginx → `ui:8080`, set header `X-Forwarded-*`
- [x] (Tùy chọn) TLS self-signed, gzip, giới hạn body size

**DoD:**
- [x] `docker compose up -d` từ máy sạch là chạy được, `docker compose ps` toàn bộ `healthy`
- [x] Smoke test ARCHITECTURE.md §8 pass: đơn hàng có trong Postgres
- [x] `docker compose down && up` → dữ liệu Postgres vẫn còn (volume)
- [x] Giải thích được: vì sao multi-stage, vì sao non-root, DNS nội bộ của compose hoạt động thế nào

---

## GĐ 2 – Hạ tầng (Terraform + Ansible) ✅

💰 *Bắt đầu tốn tiền. Đặt Budget alert trước khi `apply`.*

### 2.1 Terraform
- [x] Backend S3 cho state (+ bật versioning; lock bằng `use_lockfile` hoặc DynamoDB)
- [x] VPC, 1 public subnet (đơn giản) hoặc public + private (giống công ty hơn, nhưng NAT Gateway khoảng $32/tháng nên cân nhắc)
- [x] Security Group: SSH chỉ từ IP của bạn; 80/443 public; port RKE2 (6443, 9345, 10250, 8472/udp VXLAN…) chỉ mở trong SG nội bộ
- [x] 3 EC2 (1 server t3.large + 2 agent t3.medium), EBS gp3, 1 EIP cho node có ingress
- [x] Output IP để sinh inventory Ansible
- [ ] Tách module (`network`, `compute`) *(hiện tách theo file; refactor module sau)* · [x] `variables.tf` / `terraform.tfvars`

### 2.2 Ansible
- [x] Role `common`: update, SSH hardening (tắt password/root login), `fail2ban`, tắt `ufw` (dùng SG), tắt swap *(chưa làm: user deploy riêng, timezone)*
- [x] Role `rke2-server`, `rke2-agent`: cài RKE2, join token để trong Ansible Vault
- [x] Lấy `kubeconfig` về máy local
- [x] Cài Longhorn (yêu cầu `open-iscsi`, `nfs-common` trên node), đặt làm default StorageClass

**DoD:**
- [x] `terraform apply` + `ansible-playbook site.yml` → `kubectl get nodes` có 3 node `Ready`
- [ ] Destroy rồi dựng lại từ đầu được, không sửa tay *(kiểm chứng ở lần dựng đầu của GĐ3)*
- [x] Giải thích được vai trò server/agent của RKE2 và vì sao cần SG nội bộ
- [x] Playbook chạy lần 2: `changed=0` (đã kiểm chứng)

---

## GĐ 3 – Kubernetes *(hiện tại)*

### 3.1 Manifest thuần (viết tay trước khi dùng Helm)
- [ ] Namespace `retail-store`
- [ ] StatefulSet + headless Service + PVC (Longhorn) cho: MariaDB, Postgres, RabbitMQ, Redis, DynamoDB Local
- [ ] Deployment + Service cho 5 app
- [ ] ConfigMap (endpoint), Secret (password). Không commit Secret dạng plain text
- [ ] Probe: `startupProbe` (Java khởi động chậm), `readinessProbe`, `livenessProbe` dùng path ở ARCHITECTURE.md §2
- [ ] `resources.requests/limits` theo ARCHITECTURE.md §6
- [ ] `securityContext`: `runAsNonRoot`, `readOnlyRootFilesystem`, drop ALL capabilities
- [ ] Ingress Controller (RKE2 có sẵn ingress-nginx) → Ingress cho UI

### 3.2 Helm
- [ ] Đóng gói thành chart `charts/retail-store` (dùng subchart hoặc template chung cho 5 app)
- [ ] `values.yaml` + `values-prod.yaml`; `helm lint`, `helm template` để kiểm tra

### 3.3 Độ tin cậy
- [ ] HPA cho ui, catalog (cần metrics-server)
- [ ] PodDisruptionBudget cho app
- [ ] NetworkPolicy: chỉ cho phép đúng các luồng trong sơ đồ kiến trúc
- [ ] CronJob backup Postgres + MariaDB (`pg_dump`/`mysqldump`) lên S3

**DoD:**
- [ ] Smoke test pass qua Ingress
- [ ] `kubectl delete pod orders-db-0` → pod lên lại, đơn hàng cũ vẫn còn
- [ ] Xóa DB, restore từ backup S3 thành công
- [ ] Giải thích được: StatefulSet và Deployment khác nhau thế nào, readiness và liveness khác nhau thế nào, PVC được bind ra sao

---

## GĐ 4 – CI/CD

### 4.1 CI (Jenkins)
- [ ] Jenkins chạy trong cluster (Helm) hoặc trên 1 EC2 riêng. Agent build dạng pod (Kubernetes plugin)
- [ ] Pipeline: checkout → unit test → SonarQube scan + Quality Gate → build image → scan image (Trivy) → push registry
- [ ] Chỉ build service có thay đổi (path-based)
- [ ] Tag image theo git SHA, không dùng `latest`
- [ ] Registry: Docker Hub / GHCR (miễn phí). ECR cũng được, nhưng tốn phí lưu trữ

### 4.2 CD (ArgoCD + GitOps)
- [ ] Repo `retail-store-gitops` chứa values cho từng môi trường
- [ ] Jenkins cập nhật image tag trong repo GitOps (commit/PR) → ArgoCD sync
- [ ] Mô hình App-of-Apps; bật auto-sync + self-heal
- [ ] Quản lý secret: Sealed Secrets hoặc External Secrets

**DoD:**
- [ ] Merge PR sửa code → image mới tự động chạy trên cluster, không gõ lệnh tay
- [ ] Rollback bằng `git revert` trên repo GitOps

---

## GĐ 5 – Monitoring & Observability
- [ ] kube-prometheus-stack (Prometheus, Alertmanager, Grafana)
- [ ] `ServiceMonitor` cho 5 app (path metrics ở ARCHITECTURE.md §2)
- [ ] Loki + Promtail/Alloy để gom log
- [ ] Dashboard: RED metrics (Rate, Errors, Duration) cho mỗi service; JVM; DB
- [ ] Alert: pod crashloop, error rate > 5%, PVC sắp đầy, node hết RAM → gửi Telegram/Slack/email
- [ ] (Tùy chọn) Tracing: OpenTelemetry Collector + Tempo/Jaeger
- [ ] Chạy `src/load-generator`, quan sát HPA scale; dùng endpoint `/chaos/*` để giả lập sự cố và kiểm tra alert

**DoD:** gây lỗi bằng `/chaos/status/500` → alert bắn → tìm ra nguyên nhân bằng dashboard + log.

---

## GĐ 6 – Hoàn thiện
- [ ] README: sơ đồ kiến trúc hạ tầng (AWS → RKE2 → app), cách dựng từ đầu
- [ ] Runbook: DB pod lỗi, node chết, disk đầy, rollback deploy
- [ ] `docs/incident-log.md`: các lỗi đã gặp, nguyên nhân, cách sửa
- [ ] So sánh với Helm/Terraform của upstream, ghi lại điểm khác biệt và điều học được
- [ ] `terraform destroy` 🧹

---

## Kiểm soát chi phí (áp dụng từ GĐ2)
| Hạng mục | Ước tính khi chạy 24/7 (us-east-1) |
|---|---|
| 1× t3.large + 2× t3.medium | khoảng $0.17/giờ ≈ $120/tháng |
| EBS gp3 3×30 GB | khoảng $7/tháng |
| EIP (đang gắn vào instance chạy) | khoảng $3.6/tháng (IPv4 public đều tính phí) |

→ Với $180 credit: **bắt buộc stop instance khi không học**, hoặc `destroy` cuối mỗi buổi. Như vậy GĐ2 phải dựng lại được nhanh. Cân nhắc dùng Spot cho 2 agent.

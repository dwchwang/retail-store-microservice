# Kế hoạch học DevOps với Retail Store Sample App

## 1. Bối cảnh

Tôi đang học DevOps theo roadmap 12 bước (Git → Lập trình → Linux → Networking & Security → Server management → Containers → Kubernetes → IaC → CI/CD → Monitoring → Cloud → SE practices).

Mục tiêu: **tự triển khai và vận hành trọn vẹn một hệ thống microservice** giống như trên server công ty, không chỉ học lý thuyết hay chạy file có sẵn.

## 2. Repo được chọn

**[aws-containers/retail-store-sample-app](https://github.com/aws-containers/retail-store-sample-app)**

Lý do chọn:
- **Được cập nhật đều** (bản v1.6.2 ra tháng 07/2026), dùng Spring Boot 3 và thư viện mới.
- **Microservice đa ngôn ngữ:** UI (Java), Catalog (Go), Cart (Java), Orders (Java), Checkout (Node.js).
- **Đủ các thành phần dữ liệu thực tế:**

| Service | Lưu trữ |
|---|---|
| Catalog | MySQL / MariaDB |
| Cart | DynamoDB Local (code không hỗ trợ MongoDB) |
| Orders | PostgreSQL + RabbitMQ |
| Checkout | Redis |

- **Sẵn sàng cho monitoring:** có metrics Prometheus, tracing OpenTelemetry và load generator.
- **Chạy được hoàn toàn tự host**, không phụ thuộc dịch vụ managed của AWS.

## 3. Môi trường triển khai

Mô phỏng hạ tầng tự quản như ở công ty:

- **AWS chỉ dùng:** EC2, VPC, Security Group, EBS, S3 (lưu Terraform state). **Không** dùng EKS/RDS/ElastiCache/Amazon MQ.
- **Kubernetes:** RKE2, gồm 1 server + 2 agent (t3.medium/t3.large).
- **Storage:** Longhorn (hoặc local-path).
- **Mọi DB/queue chạy bằng StatefulSet** trong cluster.
- Ngân sách: $180 credit, đặt Budget alert $20/$50/$100, tắt máy khi không học.

## 4. Lộ trình

- [ ] **GĐ 1 – Docker:** tự viết Dockerfile multi-stage cho 5 service; `docker-compose.yml` chạy app + 5 thành phần dữ liệu + Nginx reverse proxy. *Xong khi:* đặt hàng thành công và đơn hàng có trong PostgreSQL.
- [ ] **GĐ 2 – Hạ tầng:** Terraform (VPC, subnet, SG, 3 EC2, EIP, state trên S3); Ansible (hardening Linux, cài RKE2, Longhorn). *Xong khi:* dựng lại cluster từ đầu bằng 2 lệnh.
- [ ] **GĐ 3 – Kubernetes:** Deployment, StatefulSet + PVC, Secret, ConfigMap, Ingress, probe → đóng gói Helm chart; thêm HPA, PDB; CronJob backup DB. *Xong khi:* xóa pod DB mà dữ liệu vẫn còn, restore được từ backup.
- [ ] **GĐ 4 – CI/CD:** Jenkins (test → SonarQube → build → push image); ArgoCD + repo GitOps riêng. *Xong khi:* merge PR là tự deploy.
- [ ] **GĐ 5 – Monitoring:** kube-prometheus-stack, Loki, dashboard, alert; chạy load generator để xem HPA scale.
- [ ] **GĐ 6 – Hoàn thiện:** README có sơ đồ kiến trúc, runbook xử lý sự cố, nhật ký lỗi đã gặp.

## 5. Nguyên tắc học

1. **Chỉ giữ thư mục `src/`.** Bỏ qua Helm chart, Terraform, manifest có sẵn của repo gốc. Tự viết trước, so sánh với bản gốc sau.
2. **Mọi thứ là code.** Không sửa tay trên server; hạ tầng phải dựng lại được bất cứ lúc nào.
3. **Hiểu rồi mới làm tiếp.** Mỗi giai đoạn phải chạy được và giải thích được trước khi sang giai đoạn sau.

## 6. Hướng dẫn cho AI agent

Bạn đóng vai **mentor DevOps**, làm việc cùng tôi trên repo này. Khi hỗ trợ:

- **Ưu tiên để tôi tự làm.** Giải thích khái niệm và gợi ý hướng đi trước; chỉ đưa code hoàn chỉnh khi tôi yêu cầu hoặc đã thử mà vẫn kẹt.
- **Giải thích "vì sao"**, không chỉ "làm thế nào". Nêu cách làm phổ biến ở môi trường production.
- **Bám đúng giai đoạn hiện tại** trong mục 4; không nhảy cóc sang công cụ của giai đoạn sau.
- **Review code tôi viết:** chỉ ra lỗi bảo mật, cấu hình sai, thiếu best practice (resource limits, probe, secret để lộ, image chạy root…).
- **Khi debug:** hướng dẫn tôi cách tự điều tra (`kubectl describe`, `logs`, `events`, `journalctl`…) trước khi đưa đáp án.
- **Cảnh báo chi phí AWS** khi có thao tác tạo tài nguyên tốn tiền; nhắc `terraform destroy` khi xong.
- **Cuối mỗi buổi:** tóm tắt việc đã làm, cập nhật checklist ở mục 4, gợi ý việc tiếp theo.
- Trả lời bằng **tiếng Việt**, thuật ngữ kỹ thuật giữ nguyên tiếng Anh.

**Giai đoạn hiện tại:** GĐ 1 – Docker
# GĐ2 – Hiểu Terraform & Ansible qua dự án

> Đọc cùng guide thực hành [gd2-infra.md](../guides/gd2-infra.md). File này giải thích **từng phần trong guide là gì, vì sao làm vậy, và áp dụng kiến thức ra sao**.

## 1. Bức tranh tổng thể: 3 lớp, mỗi lớp một công cụ

```
┌──────────────────────────────────────────────────────────────────┐
│ Lớp 3: K8s cluster   (RKE2 + Longhorn)       ← GĐ3 deploy app vào đây │
├──────────────────────────────────────────────────────────────────┤
│ Lớp 2: Cấu hình OS   (Ansible)    "bên trong máy có gì"            │
├──────────────────────────────────────────────────────────────────┤
│ Lớp 1: Hạ tầng       (Terraform)  "có những máy nào, mạng ra sao"   │
└──────────────────────────────────────────────────────────────────┘
```

**Vì sao cần 2 công cụ?**
- **Terraform** nói chuyện với **API của AWS** để tạo, sửa, xoá tài nguyên. Nó không vào được bên trong máy.
- **Ansible** **SSH vào máy** để cài và cấu hình. Nó không tạo được máy.

Ở công ty, cách chia này rất phổ biến: Terraform lo **provisioning**, Ansible lo **configuration management**.

**Cầu nối:** Terraform tạo máy xong thì biết IP. Nó ghi IP ra file `hosts.ini`, rồi Ansible đọc file đó để biết SSH vào đâu. Nhờ vậy cả cluster dựng được bằng 2 lệnh:
```bash
terraform apply        # tạo máy + sinh hosts.ini
ansible-playbook ...   # đọc hosts.ini, cấu hình máy
```

---

## 2. Terraform

### 2.1 Khái niệm cốt lõi

| Khái niệm | Là gì | Dùng ở đâu trong dự án |
|---|---|---|
| **provider** | Plugin để nói chuyện với một nền tảng | `aws` (tạo EC2, VPC…), `local` (ghi file inventory) |
| **resource** | Thứ Terraform **tạo ra và quản lý** | `aws_vpc`, `aws_instance`, `aws_eip`… |
| **data** | Thứ **đã có sẵn**, chỉ đọc | `aws_ami` (tìm AMI Ubuntu mới nhất), `aws_caller_identity` (lấy account ID) |
| **variable** | Tham số đầu vào | `admin_cidr`, `instance_type`… |
| **tfvars** | Giá trị gán cho variable | `terraform.tfvars` chứa IP của bạn |
| **output** | Giá trị in ra sau khi `apply` | IP server, lệnh SSH |
| **locals** | Biến nội bộ, tránh lặp code | `common_instance` dùng chung cho server và agent |

### 2.2 State: khái niệm quan trọng nhất

Terraform **không hỏi AWS "đang có gì"** mỗi lần chạy. Nó so sánh 3 thứ:

```
code (.tf)   ←so sánh→   state (tfstate)   ←refresh→   AWS thật
 "muốn có"                 "đã tạo gì"                  "thực tế"
```

`plan` là kết quả của phép so sánh đó: cái gì cần tạo (+), cần sửa (~), cần xoá (-).

**Vì sao để state trên S3 thay vì ở máy bạn?**
- Mất file state thì Terraform "quên" mọi thứ nó đã tạo. Tài nguyên vẫn chạy và tính tiền nhưng không ai quản lý.
- **Versioning:** state lỡ hỏng thì quay lại bản cũ được.
- **Lockfile** (`use_lockfile`): chặn 2 người, hoặc 2 job CI, `apply` cùng lúc làm hỏng state.
- Ở công ty, state luôn nằm ở remote backend, không để local.

**Vì sao tách `bootstrap/`?** Bucket chứa state không thể được quản lý bởi chính state nằm trong nó (bài toán con gà và quả trứng). Bootstrap tạo bucket một lần, dùng state local, và không bao giờ destroy.

### 2.3 Kỹ thuật dùng trong guide

| Kỹ thuật | Ý nghĩa |
|---|---|
| `count = 2` | Tạo 2 agent từ cùng một khối code. Truy cập bằng `aws_instance.agent[0]` hoặc `aws_instance.agent[*].public_ip` |
| `for_each = toset(["80","443"])` | Tạo một rule cho mỗi phần tử. Dùng khi các bản sao khác nhau về nội dung |
| `dynamic "notification"` | Sinh nhiều block lồng nhau (3 mức alert) bằng vòng lặp |
| `lifecycle { ignore_changes = [ami] }` | Canonical ra AMI mới thì Terraform **không** xoá máy cũ để tạo lại |
| `templatefile()` + `local_file` | Render template thành file thật: chính là `hosts.ini` cho Ansible |
| `default_tags` | Mọi tài nguyên được gắn tag `Project=retail-store`, giúp lọc chi phí và tìm tài nguyên sót |

### 2.4 Quy trình làm việc chuẩn
```
init  →  fmt / validate  →  plan -out=tfplan  →  (đọc kỹ)  →  apply tfplan  →  destroy
```
`plan -out` rồi `apply tfplan` đảm bảo **thứ được apply đúng là thứ bạn đã đọc**. Ở công ty, CI chạy `plan`, người review, rồi mới `apply`.

---

## 3. Mạng AWS: dữ liệu đi từ internet tới máy như thế nào

```
Internet → IGW → Route table (0.0.0.0/0 → IGW) → Subnet → Security Group → EC2
```

| Thành phần | Vai trò | Ví von |
|---|---|---|
| **VPC** `10.0.0.0/16` | Mạng riêng, cô lập của bạn | Khu đất riêng |
| **Subnet** `10.0.1.0/24` | Một dải IP nằm trong 1 AZ | Một dãy nhà |
| **Internet Gateway** | Cổng ra internet | Cổng khu |
| **Route table** | Chỉ đường: traffic đi internet thì qua IGW | Biển chỉ đường |
| **Security Group** | Firewall gắn vào từng máy, **stateful** (cho phép đi ra thì chiều về tự được cho qua) | Bảo vệ ở cửa từng nhà |
| **EIP** | Public IP cố định | Số nhà không đổi |

**Thế nào là "public subnet"?** Subnet có route `0.0.0.0/0 → IGW`, cộng với `map_public_ip_on_launch` để máy được cấp public IP. Private subnet thì phải ra ngoài qua NAT Gateway (khoảng $32/tháng), nên bỏ qua.

**Security Group, ai được vào port nào:**
- **Tự tham chiếu (self rule):** máy trong cùng SG nói chuyện thoải mái. RKE2 và Longhorn cần rất nhiều port, liệt kê từng cái thì dễ sót. Mở theo SG là cách phổ biến cho các node cùng cluster.
- **22 (SSH), 6443 (K8s API):** chỉ IP của bạn. Đây là 2 cửa quan trọng nhất.
- **80/443:** public, để người dùng vào web qua Ingress ở GĐ3.

**Vì sao chỉ server có EIP?** Khi stop rồi start, máy đổi public IP. Kubeconfig và chứng chỉ TLS của API server gắn với IP của server, nên server phải có IP cố định. Agent giao tiếp bằng **private IP** (không đổi khi stop/start), nên không cần EIP.

**Hai thiết lập bảo mật nhỏ:**
- `encrypted = true`: mã hoá ổ EBS.
- `http_tokens = "required"` (IMDSv2): chặn kiểu tấn công SSRF đánh cắp credential qua metadata của EC2.

---

## 4. Ansible

### 4.1 Khái niệm cốt lõi

| Khái niệm | Là gì | Trong dự án |
|---|---|---|
| **Inventory** | Danh sách máy và nhóm | `hosts.ini`: nhóm `[server]`, `[agent]`, và `[cluster]` = cả hai |
| **Playbook** | Kịch bản: nhóm máy nào chạy role gì, theo thứ tự nào | `site.yml` |
| **Play** | Một khối "hosts + roles" trong playbook | 4 play: common → server → agent → longhorn |
| **Role** | Gói tái sử dụng (tasks, templates, handlers) | `common`, `rke2_server`, `rke2_agent`, `longhorn` |
| **Task** | Một bước, gọi một **module** | "Install base packages" |
| **Module** | Hành động có sẵn | `apt`, `systemd`, `template`, `copy`, `file`, `fetch`… |
| **Handler** | Task chỉ chạy **khi được notify** (tức là có thay đổi) | Sửa sshd config xong mới restart ssh |
| **Template (Jinja2)** | File có biến `{{ }}` | `config.yaml.j2` của RKE2 |
| **group_vars/all** | Biến dùng chung cho mọi máy | Channel RKE2, version Longhorn |
| **Vault** | Mã hoá file chứa secret | `vault.yml` chứa RKE2 token |

### 4.2 Idempotent: nguyên tắc số 1
**Chạy 1 lần hay 10 lần thì kết quả vẫn như nhau.** Module mô tả **trạng thái mong muốn**, không phải hành động:
- `apt: name=curl state=present` nghĩa là "đảm bảo có curl". Có rồi thì bỏ qua, báo `ok` thay vì `changed`.
- Riêng `shell` thì Ansible không biết lệnh đã chạy chưa. Vì vậy phải thêm `creates: /usr/local/bin/rke2`: file đó đã tồn tại thì bỏ qua.

Chạy playbook lần 2 mà ra `changed=0` chứng tỏ playbook viết đúng. Ở công ty, nhờ tính chất này mà playbook chạy định kỳ được để sửa **drift** (khi ai đó sửa tay trên máy).

### 4.3 Thứ tự play quan trọng
```
common (cả 3 máy)  →  rke2_server  →  rke2_agent  →  longhorn
                       phải có server       agent join      cần đủ node
                       trước để agent join  vào server       Ready
```

### 4.4 Kỹ thuật dùng trong guide

| Kỹ thuật | Ý nghĩa |
|---|---|
| `become: true` | Chạy với sudo |
| `hostvars[groups['server'][0]]['private_ip']` | Agent **lấy biến của máy server** để biết join vào đâu |
| `fetch` | Kéo file từ server **về máy bạn** (kubeconfig) |
| `delegate_to: localhost` | Chạy task này trên máy bạn thay vì trên server (sửa IP trong kubeconfig) |
| `notify` + handler | Restart chỉ khi config thực sự thay đổi, tránh restart vô ích |
| `vault_password_file` | Ansible tự giải mã vault khi chạy. File mật khẩu nằm ngoài repo |

**Quy ước `vault_rke2_token` → `rke2_token`:** biến bí mật có tiền tố `vault_` và nằm trong file mã hoá; `vars.yml` trỏ tới nó. Nhìn vào `vars.yml` là biết có những biến gì, mà không lộ giá trị.

---

## 5. Nội dung từng role

### `common`: chuẩn bị và hardening OS
- Update package, cài `open-iscsi` và `nfs-common` (Longhorn cần để gắn volume vào node).
- **Tắt ufw:** firewall của máy xung đột với iptables mà CNI của K8s tự quản lý. Việc chặn mạng đã có Security Group lo.
- **Tắt swap:** kubelet cần biết chính xác RAM để lập lịch pod.
- **SSH hardening:** cấm root login, cấm password, chỉ cho đăng nhập bằng key. Kèm `fail2ban` chặn brute-force.

### `rke2_server` và `rke2_agent`
```
server-1 (control plane: API server, etcd, scheduler)
   ▲  :9345 (supervisor: agent đăng ký vào đây)
   │  token (mật khẩu chung để join)
agent-1, agent-2 (chỉ chạy pod)
```
- **token:** agent nào có đúng token mới được join, nên token phải nằm trong Vault.
- **`node-ip: private_ip`:** các node nói chuyện với nhau qua mạng nội bộ VPC (nhanh, miễn phí, không đi ra internet).
- **`tls-san`:** thêm IP public vào chứng chỉ của API server. Thiếu nó thì `kubectl` từ máy bạn sẽ báo lỗi certificate.
- Kubeconfig gốc trỏ tới `127.0.0.1`, nên guide sửa thành IP public để dùng được từ máy bạn.

### `longhorn`: storage cho K8s
- Pod là tạm thời. DB (StatefulSet ở GĐ3) cần ổ đĩa sống lâu hơn pod, tức là **PersistentVolume**.
- Longhorn biến ổ EBS của 3 node thành storage phân tán, **replicate dữ liệu sang nhiều node**. Một node chết thì dữ liệu vẫn còn.
- Đây là bản tự host thay cho EBS CSI hoặc RDS, đúng với yêu cầu "không dùng dịch vụ managed".

---

## 6. Mapping với nguyên tắc dự án

| Nguyên tắc (`devops_learning.md`) | Thể hiện trong GĐ2 |
|---|---|
| Mọi thứ là code | Không click Console. VPC, máy, cấu hình OS, cluster đều nằm trong `.tf` và `.yml` |
| Dựng lại được bất cứ lúc nào | `destroy` → `apply` → `ansible-playbook`. Idempotent và inventory tự sinh |
| Không sửa tay trên server | Muốn đổi gì thì sửa role rồi chạy lại playbook |
| Không lộ secret | Token trong Vault; state trên S3 có mã hoá; `.gitignore` chặn `tfstate`, kubeconfig, vault pass |
| Kiểm soát chi phí | Budget không trừ credit, tag chung, destroy cuối buổi |

---

## 7. Thứ tự thực hành gợi ý
1. Chạy bootstrap, mở state local ra xem bên trong có gì.
2. `plan` main, đọc từng resource sắp được tạo.
3. `apply`, SSH thử vào máy.
4. `ansible all -m ping`.
5. Chạy playbook.
6. Chạy playbook lần 2 để thấy `changed=0`.
7. `destroy`.

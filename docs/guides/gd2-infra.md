# GĐ2 – Dựng hạ tầng: Terraform + Ansible → RKE2 + Longhorn

**Kết quả cuối:** 2 lệnh dựng được cluster 3 node từ đầu:
```bash
terraform -chdir=infra/terraform/main apply
ansible-playbook -i infra/ansible/inventory/hosts.ini infra/ansible/site.yml
```

**Thiết kế đã chốt**
| Hạng mục | Giá trị |
|---|---|
| Region | `ap-southeast-1` (Singapore) |
| Mạng | 1 VPC `10.0.0.0/16`, 1 public subnet `10.0.1.0/24` |
| SSH, K8s API (6443) | chỉ mở cho IP của bạn |
| HTTP/HTTPS (80/443) | mở public (dùng cho Ingress ở GĐ3) |
| Traffic giữa các node | cho phép toàn bộ (SG tự tham chiếu chính nó) |
| Node | `server-1` t3.large (EIP), `agent-1`, `agent-2` t3.medium; Ubuntu 24.04; gp3 40 GB |
| Terraform state | S3 (versioning + lockfile) |

```
            Internet
               │
        ┌──────▼──────┐
        │     IGW     │
        └──────┬──────┘
   VPC 10.0.0.0/16 │ public subnet 10.0.1.0/24
   ┌───────────────┼──────────────────────────────┐
   │  ┌────────────▼──┐  ┌───────────┐  ┌───────────┐ │
   │  │ server-1 (EIP)│  │  agent-1  │  │  agent-2  │ │
   │  │ rke2-server   │◀─┤ rke2-agent│  │ rke2-agent│ │
   │  │ etcd, API     │  │           │  │           │ │
   │  └───────────────┘  └───────────┘  └───────────┘ │
   │   SG "cluster": node↔node mở hết; 22/6443 ← IP bạn; 80/443 ← 0.0.0.0/0 │
   └──────────────────────────────────────────────────┘
```

> 💰 **Chi phí (ap-southeast-1, on-demand):** t3.large khoảng $0.106/giờ, t3.medium khoảng $0.053/giờ, cộng thêm public IPv4 $0.005/giờ/IP.
> **≈ $0.23/giờ ≈ $5.5/ngày nếu chạy 24/7.** EBS 3×40 GB khoảng $10/tháng.
> → **Hết buổi thì `terraform destroy`** (dựng lại mất khoảng 15 phút). Đó cũng là cách kiểm tra DoD "dựng lại được".

---

## Bước 0 – Chuẩn bị máy local

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform ansible awscli kubectl
terraform version    # cần >= 1.10 (để dùng S3 lockfile)
```

### 0.1 IAM user (không dùng root account)
1. AWS Console → IAM → Users → Create user `devops-admin`, gán policy `AdministratorAccess` (môi trường lab).
2. Bật MFA cho cả root lẫn user này.
3. Tạo Access key (loại CLI), rồi:
```bash
aws configure --profile retail
# region: ap-southeast-1, output: json
export AWS_PROFILE=retail          # thêm vào ~/.zshrc
aws sts get-caller-identity        # phải hiện ARN của devops-admin
```

### 0.2 SSH key
```bash
ssh-keygen -t ed25519 -f ~/.ssh/retail-store -C "retail-store"
# Có đặt passphrase → bắt buộc nạp vào ssh-agent, nếu không Ansible sẽ báo "Permission denied (publickey)":
ssh-add --apple-use-keychain ~/.ssh/retail-store
```

### 0.3 Cấu trúc thư mục
```
infra/
├── terraform/
│   ├── bootstrap/      # S3 state bucket + Budget (state local, chạy 1 lần)
│   └── main/           # VPC, SG, EC2 (state trên S3)
└── ansible/
    ├── ansible.cfg
    ├── site.yml
    ├── inventory/      # hosts.ini do Terraform sinh ra
    ├── group_vars/all/ # vars.yml + vault.yml (mã hoá)
    └── roles/{common,rke2_server,rke2_agent,longhorn}
```
```bash
mkdir -p infra/terraform/{bootstrap,main} infra/ansible/{inventory,group_vars/all,templates}
mkdir -p infra/ansible/roles/{common,rke2_server,rke2_agent,longhorn}/{tasks,templates,handlers}
```

---

## Bước 1 – Terraform bootstrap: S3 state + Budget

> Bài toán "con gà – quả trứng": bucket chứa state không thể nằm trong state của chính nó. Vì vậy tách riêng bootstrap, chạy 1 lần, state để local.
**`infra/terraform/bootstrap/main.tf`**
```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region = "ap-southeast-1"
  default_tags {
    tags = { Project = "retail-store", ManagedBy = "terraform" }
  }
}

variable "alert_email" {
  type = string
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "tfstate" {
  bucket = "retail-store-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_budgets_budget" "monthly" {
  name         = "retail-store-monthly"
  budget_type  = "COST"
  limit_amount = "100"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Quan trọng: không trừ credit, nếu không alert sẽ không bao giờ bắn
  cost_types {
    include_credit = false
    include_refund = false
  }

  dynamic "notification" {
    for_each = [20, 50, 100]   # % của $100 → $20 / $50 / $100
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.alert_email]
    }
  }
}

output "state_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}
```

```bash
cd infra/terraform/bootstrap
terraform init
terraform apply -var="alert_email=you@example.com"
# ghi lại output state_bucket
```
> Không bao giờ destroy bootstrap. S3 vài KB và Budget đều miễn phí.

---

## Bước 2 – Terraform main: VPC, SG, EC2

**`infra/terraform/main/versions.tf`**
```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 6.0" }
    local = { source = "hashicorp/local", version = "~> 2.5" }
  }

  backend "s3" {
    bucket       = "retail-store-tfstate-<ACCOUNT_ID>"   # ← output state_bucket
    key          = "main/terraform.tfstate"
    region       = "ap-southeast-1"
    encrypt      = true
    use_lockfile = true   # khoá state bằng file .tflock trên S3, không cần DynamoDB
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "retail-store", ManagedBy = "terraform" }
  }
}
```

**`infra/terraform/main/variables.tf`**
```hcl
variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "admin_cidr" {
  description = "IP của bạn dạng x.x.x.x/32"
  type        = string
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/retail-store.pub"
}

variable "server_instance_type" {
  type    = string
  default = "t3.large"
}

variable "agent_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "agent_count" {
  type    = number
  default = 2
}

variable "root_volume_size" {
  type    = number
  default = 40
}
```

**`infra/terraform/main/terraform.tfvars`** (bị `.gitignore` vì chứa IP nhà bạn; commit bản mẫu `terraform.tfvars.example`)
```hcl
admin_cidr = "1.2.3.4/32"   # ← curl -s https://checkip.amazonaws.com
```

**`infra/terraform/main/network.tf`**
```hcl
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "retail-store-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "retail-store-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "retail-store-public-a" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "retail-store-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
```

**`infra/terraform/main/security.tf`**
```hcl
resource "aws_security_group" "cluster" {
  name        = "retail-store-cluster"
  description = "RKE2 cluster nodes"
  vpc_id      = aws_vpc.main.id
}

# Node ↔ node: mở hết (RKE2 6443/9345/10250/2379-2380, VXLAN 8472/udp, Longhorn…)
resource "aws_vpc_security_group_ingress_rule" "self" {
  security_group_id            = aws_security_group.cluster.id
  referenced_security_group_id = aws_security_group.cluster.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.cluster.id
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "kube_api" {
  security_group_id = aws_security_group.cluster.id
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each          = toset(["80", "443"])
  security_group_id = aws_security_group.cluster.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.cluster.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
```

**`infra/terraform/main/compute.tf`**
```hcl
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_key_pair" "admin" {
  key_name   = "retail-store"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

locals {
  common_instance = {
    ami                    = data.aws_ami.ubuntu.id
    subnet_id              = aws_subnet.public.id
    vpc_security_group_ids = [aws_security_group.cluster.id]
    key_name               = aws_key_pair.admin.key_name
  }
}

resource "aws_instance" "server" {
  ami                    = local.common_instance.ami
  instance_type          = var.server_instance_type
  subnet_id              = local.common_instance.subnet_id
  vpc_security_group_ids = local.common_instance.vpc_security_group_ids
  key_name               = local.common_instance.key_name

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  tags = { Name = "server-1", Role = "rke2-server" }

  # AMI mới ra không làm tạo lại máy
  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_instance" "agent" {
  count                  = var.agent_count
  ami                    = local.common_instance.ami
  instance_type          = var.agent_instance_type
  subnet_id              = local.common_instance.subnet_id
  vpc_security_group_ids = local.common_instance.vpc_security_group_ids
  key_name               = local.common_instance.key_name

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = { Name = "agent-${count.index + 1}", Role = "rke2-agent" }

  lifecycle {
    ignore_changes = [ami]
  }
}

# IP cố định cho server: kubeconfig và tls-san không đổi khi stop/start
resource "aws_eip" "server" {
  instance = aws_instance.server.id
  domain   = "vpc"
  tags     = { Name = "server-1-eip" }
}
```

**`infra/terraform/main/outputs.tf`**: sinh inventory cho Ansible
```hcl
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../../ansible/inventory/hosts.ini"
  file_permission = "0644"
  content = templatefile("${path.module}/inventory.tftpl", {
    server = {
      name       = "server-1"
      public_ip  = aws_eip.server.public_ip
      private_ip = aws_instance.server.private_ip
    }
    agents = [for i, a in aws_instance.agent : {
      name       = "agent-${i + 1}"
      public_ip  = a.public_ip
      private_ip = a.private_ip
    }]
  })
}

output "server_public_ip" {
  value = aws_eip.server.public_ip
}

output "agent_public_ips" {
  value = aws_instance.agent[*].public_ip
}

output "ssh_server" {
  value = "ssh -i ~/.ssh/retail-store ubuntu@${aws_eip.server.public_ip}"
}
```

**`infra/terraform/main/inventory.tftpl`**
```ini
[server]
${server.name} ansible_host=${server.public_ip} private_ip=${server.private_ip}

[agent]
%{ for a in agents ~}
${a.name} ansible_host=${a.public_ip} private_ip=${a.private_ip}
%{ endfor ~}

[cluster:children]
server
agent
```

### Chạy
```bash
cd infra/terraform/main
terraform init
terraform fmt -recursive && terraform validate
terraform plan -out=tfplan        # đọc kỹ: phải tạo khoảng 15 resource
terraform apply tfplan
cat ../../ansible/inventory/hosts.ini
ssh -i ~/.ssh/retail-store ubuntu@$(terraform output -raw server_public_ip)
```

> Thêm vào `.gitignore` nếu chưa có: `infra/ansible/inventory/hosts.ini` (chứa IP, sinh lại được). **Nên commit** `.terraform.lock.hcl`.

---

## Bước 3 – Ansible

**`infra/ansible/ansible.cfg`**
```ini
[defaults]
inventory          = inventory/hosts.ini
remote_user        = ubuntu
private_key_file   = ~/.ssh/retail-store
# lab: IP đổi mỗi lần dựng lại
host_key_checking  = False
vault_password_file = ~/.ansible/retail-vault-pass
callback_result_format = yaml
forks              = 10

[ssh_connection]
pipelining = True
```

### 3.1 Biến + secret
**`infra/ansible/group_vars/all/vars.yml`**
```yaml
rke2_channel: stable           # hoặc pin: rke2_version: v1.xx.y+rke2r1
rke2_token: "{{ vault_rke2_token }}"
rke2_server_private_ip: "{{ hostvars[groups['server'][0]]['private_ip'] }}"
rke2_server_public_ip: "{{ hostvars[groups['server'][0]]['ansible_host'] }}"
longhorn_version: v1.9.1       # kiểm tra bản mới nhất: github.com/longhorn/longhorn/releases
kubeconfig_local_path: "~/.kube/retail-store.yaml"
```

Tạo token và mã hoá bằng Vault:
```bash
mkdir -p ~/.ansible && openssl rand -base64 32 > ~/.ansible/retail-vault-pass
chmod 600 ~/.ansible/retail-vault-pass

cd infra/ansible
echo "vault_rke2_token: $(openssl rand -hex 32)" > group_vars/all/vault.yml
ansible-vault encrypt group_vars/all/vault.yml
ansible-vault view group_vars/all/vault.yml     # kiểm tra
```
> `vault.yml` đã mã hoá thì **được commit**. File `~/.ansible/retail-vault-pass` thì **không bao giờ** commit.

### 3.2 Role `common`: hardening + chuẩn bị node
**`roles/common/tasks/main.yml`**
```yaml
- name: Set hostname
  ansible.builtin.hostname:
    name: "{{ inventory_hostname }}"

- name: Upgrade packages
  ansible.builtin.apt:
    update_cache: true
    upgrade: dist
    cache_valid_time: 3600

- name: Install base packages (open-iscsi, nfs-common cho Longhorn)
  ansible.builtin.apt:
    name: [curl, jq, open-iscsi, nfs-common, fail2ban, unattended-upgrades]
    state: present

- name: Enable iscsid (Longhorn cần)
  ansible.builtin.systemd:
    name: iscsid
    enabled: true
    state: started

- name: Disable ufw (dùng Security Group; ufw xung đột với CNI của RKE2)
  ansible.builtin.systemd:
    name: ufw
    enabled: false
    state: stopped
  failed_when: false

- name: Disable swap
  ansible.builtin.command: swapoff -a
  changed_when: false

- name: Harden SSH
  ansible.builtin.copy:
    dest: /etc/ssh/sshd_config.d/99-hardening.conf
    mode: "0644"
    content: |
      PermitRootLogin no
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      MaxAuthTries 3
      X11Forwarding no
  notify: Restart ssh

- name: Enable fail2ban
  ansible.builtin.systemd:
    name: fail2ban
    enabled: true
    state: started
```

**`roles/common/handlers/main.yml`**
```yaml
- name: Restart ssh
  ansible.builtin.systemd:
    name: ssh
    state: restarted
```

### 3.3 Role `rke2_server`
**`roles/rke2_server/templates/config.yaml.j2`**
```yaml
token: {{ rke2_token }}
node-name: {{ inventory_hostname }}
node-ip: {{ private_ip }}
node-external-ip: {{ ansible_host }}
# Bắt buộc: không có dòng này API server quảng bá bằng IP public → pod gọi API bị SG chặn
advertise-address: {{ private_ip }}
tls-san:
  - {{ ansible_host }}
  - {{ private_ip }}
write-kubeconfig-mode: "0600"
```

**`roles/rke2_server/tasks/main.yml`**
```yaml
- name: Create RKE2 config dir
  ansible.builtin.file:
    path: /etc/rancher/rke2
    state: directory
    mode: "0755"

- name: Write RKE2 server config
  ansible.builtin.template:
    src: config.yaml.j2
    dest: /etc/rancher/rke2/config.yaml
    mode: "0600"
  notify: Restart rke2-server

- name: Install RKE2 server
  ansible.builtin.shell: |
    set -o pipefail
    curl -sfL https://get.rke2.io | INSTALL_RKE2_CHANNEL={{ rke2_channel }} sh -
  args:
    executable: /bin/bash
    creates: /usr/local/bin/rke2

- name: Start rke2-server
  ansible.builtin.systemd:
    name: rke2-server
    enabled: true
    state: started

- name: Wait for supervisor port 9345
  ansible.builtin.wait_for:
    port: 9345
    timeout: 300

- name: Symlink kubectl
  ansible.builtin.file:
    src: /var/lib/rancher/rke2/bin/kubectl
    dest: /usr/local/bin/kubectl
    state: link

- name: Read kubeconfig
  ansible.builtin.slurp:
    src: /etc/rancher/rke2/rke2.yaml
  register: rke2_kubeconfig

# Ghi file local một lần với IP public đã thay sẵn → chạy lại không còn "changed"
- name: Write local kubeconfig (public IP)
  delegate_to: localhost
  become: false
  ansible.builtin.copy:
    content: "{{ rke2_kubeconfig.content | b64decode | replace('https://127.0.0.1:6443', 'https://' + ansible_host + ':6443') }}"
    dest: "{{ kubeconfig_local_path }}"
    mode: "0600"
```

**`roles/rke2_server/handlers/main.yml`**
```yaml
- name: Restart rke2-server
  ansible.builtin.systemd:
    name: rke2-server
    state: restarted
```

### 3.4 Role `rke2_agent`
**`roles/rke2_agent/templates/config.yaml.j2`**
```yaml
server: https://{{ rke2_server_private_ip }}:9345
token: {{ rke2_token }}
node-name: {{ inventory_hostname }}
node-ip: {{ private_ip }}
node-external-ip: {{ ansible_host }}
```

**`roles/rke2_agent/tasks/main.yml`**
```yaml
- name: Create RKE2 config dir
  ansible.builtin.file:
    path: /etc/rancher/rke2
    state: directory
    mode: "0755"

- name: Write RKE2 agent config
  ansible.builtin.template:
    src: config.yaml.j2
    dest: /etc/rancher/rke2/config.yaml
    mode: "0600"
  notify: Restart rke2-agent

- name: Install RKE2 agent
  ansible.builtin.shell: |
    set -o pipefail
    curl -sfL https://get.rke2.io | INSTALL_RKE2_CHANNEL={{ rke2_channel }} INSTALL_RKE2_TYPE=agent sh -
  args:
    executable: /bin/bash
    creates: /usr/local/bin/rke2

- name: Start rke2-agent
  ansible.builtin.systemd:
    name: rke2-agent
    enabled: true
    state: started
```

**`roles/rke2_agent/handlers/main.yml`**
```yaml
- name: Restart rke2-agent
  ansible.builtin.systemd:
    name: rke2-agent
    state: restarted
```

### 3.5 Role `longhorn` (chạy trên server)
**`roles/longhorn/tasks/main.yml`**
```yaml
- name: Wait for all nodes Ready
  ansible.builtin.command: >
    kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml
    wait --for=condition=Ready nodes --all --timeout=600s
  changed_when: false

- name: Get installed Longhorn version
  ansible.builtin.command: >
    kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml -n longhorn-system
    get daemonset longhorn-manager -o jsonpath={.spec.template.spec.containers[0].image}
  register: longhorn_current
  changed_when: false
  failed_when: false

# Chỉ apply khi chưa cài hoặc đổi longhorn_version → idempotent
- name: Install Longhorn
  ansible.builtin.command: >
    kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f
    https://raw.githubusercontent.com/longhorn/longhorn/{{ longhorn_version }}/deploy/longhorn.yaml
  when: longhorn_version not in longhorn_current.stdout

- name: Wait for Longhorn manager
  ansible.builtin.command: >
    kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml -n longhorn-system
    rollout status daemonset/longhorn-manager --timeout=600s
  changed_when: false
```

### 3.6 Playbook
**`infra/ansible/site.yml`**
```yaml
- name: Prepare all nodes
  hosts: cluster
  become: true
  roles: [common]

- name: RKE2 server
  hosts: server
  become: true
  roles: [rke2_server]

- name: RKE2 agents
  hosts: agent
  become: true
  roles: [rke2_agent]

- name: Storage
  hosts: server
  become: true
  roles: [longhorn]
```

### Chạy
```bash
cd infra/ansible
ansible all -m ping                       # cả 3 node phải trả về pong
ansible-playbook site.yml --syntax-check
ansible-playbook site.yml                 # khoảng 10–15 phút
```

---

## Bước 4 – Kiểm tra (DoD)

```bash
export KUBECONFIG=~/.kube/retail-store.yaml
kubectl get nodes -o wide                 # 3 node Ready
kubectl get pods -A                       # không có pod CrashLoop
kubectl -n longhorn-system get pods
kubectl get storageclass                  # longhorn (default)
```

Test PVC:
```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: test-pvc }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: test-pod }
spec:
  containers:
    - name: c
      image: busybox
      command: ["sh", "-c", "echo hello > /data/f && sleep 3600"]
      volumeMounts: [{ name: d, mountPath: /data }]
  volumes:
    - name: d
      persistentVolumeClaim: { claimName: test-pvc }
EOF
kubectl get pvc test-pvc                  # Bound
kubectl delete pod test-pod pvc test-pvc
```

Chạy lại playbook lần 2 → `changed=0` (hoặc gần 0). Đó là **idempotent**.

**Checklist DoD**
- [ ] `kubectl get nodes` có 3 node `Ready`
- [ ] PVC Longhorn `Bound`
- [ ] Playbook chạy lần 2 không thay đổi gì
- [ ] `terraform destroy` → `apply` → `ansible-playbook` dựng lại từ đầu thành công
- [ ] SSH bằng password hoặc root bị từ chối

---

## Bước 5 – Dọn dẹp cuối buổi
```bash
terraform -chdir=infra/terraform/main destroy
```
Kiểm tra trong Console: EC2 → không còn instance; EIP → không còn IP đang giữ (EIP không gắn vào máy nào vẫn tính tiền).

---

## Lỗi hay gặp
| Triệu chứng | Kiểm tra |
|---|---|
| `terraform init` lỗi backend | Tên bucket trong `versions.tf` sai, hoặc thiếu `AWS_PROFILE` |
| SSH timeout | IP nhà bạn đổi → sửa `admin_cidr`, `terraform apply` |
| Agent không join | Trên agent: `sudo journalctl -u rke2-agent -f`; kiểm tra token, IP server, SG self-rule |
| `kubectl` local timeout | Port 6443 chưa mở cho IP bạn; kubeconfig chưa đổi sang IP public |
| Longhorn pod CrashLoop | `iscsid` chưa chạy trên node: `systemctl status iscsid` |
| Node `NotReady` | `sudo journalctl -u rke2-server -f`; RAM trên t3.medium: `free -m` |
| `rke2-canal` CrashLoop, log `dial tcp 10.43.0.1:443: i/o timeout` | `kubectl get endpoints kubernetes` ra IP public → thiếu `advertise-address: <private_ip>` trong config của server |

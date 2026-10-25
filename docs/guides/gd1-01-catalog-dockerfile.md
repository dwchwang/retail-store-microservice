# GĐ1 – Bước 1: Container hoá Catalog (Go)

**Mục tiêu:** đóng gói `catalog` thành image nhỏ, an toàn, build nhanh, chạy được trên EC2 (amd64) dù bạn build trên Mac.

**File liên quan:**
- `src/catalog/Dockerfile`: bản của chúng ta
- `src/catalog/.dockerignore`
- `src/catalog/Dockerfile.upstream`: bản gốc AWS, để so sánh

---

## 1. Hiểu service trước khi đóng gói

| Câu hỏi | Trả lời (ảnh hưởng đến Dockerfile) |
|---|---|
| Ngôn ngữ/version? | Go 1.25 (`go.mod`) → base image `golang:1.25` |
| Entry point? | `main.go` ở thư mục gốc → `go build .` |
| Cần file nào lúc chạy? | **Không.** `products.json`/`tags.json` được nhúng vào binary bằng `//go:embed` → runtime chỉ cần đúng 1 file binary |
| Có cần CGO không? | Driver MySQL là pure Go → **không**. *Ngoại lệ:* provider `in-memory` dùng SQLite (`go-sqlite3`, cần CGO), nên image này **không chạy được chế độ in-memory**. Ta luôn dùng `mysql`, nên chấp nhận |
| Port? | 8080 (env `PORT`) |
| Cấu hình? | Toàn bộ qua env `RETAIL_CATALOG_*` (xem ARCHITECTURE.md §4) |

> **Bài học DevOps:** luôn trả lời 6 câu này trước khi viết Dockerfile cho bất kỳ app nào. Trên thực tế, đa số lỗi "build được mà chạy không được" đều do thiếu file lúc runtime hoặc do CGO/glibc.

---

## 2. Giải thích Dockerfile từng phần

### `# syntax=docker/dockerfile:1`
Bật cú pháp BuildKit mới nhất, cần cho `RUN --mount=type=cache`.

### Stage 1 – `build`
```dockerfile
FROM golang:${GO_VERSION}-alpine AS build
```
Stage này có đầy đủ compiler và toolchain (khoảng 300 MB), nhưng **không đi vào image cuối**. Đó là ý nghĩa của multi-stage: công cụ build nằm lại ở stage build.

```dockerfile
COPY go.mod go.sum ./
RUN go mod download
COPY . .
```
**Layer caching.** Docker cache từng layer; một layer chỉ build lại khi input của nó thay đổi.
- Sửa code `.go` → chỉ layer `COPY . .` trở đi bị build lại, bước `go mod download` (tải dependency) dùng cache.
- Nếu viết `COPY . .` ngay từ đầu thì mỗi lần sửa 1 dòng code lại phải tải lại toàn bộ dependency.

Nguyên tắc chung cho mọi ngôn ngữ: **copy file khai báo dependency → cài dependency → copy code** (Java: `pom.xml`, Node: `package.json` + `yarn.lock`).

```dockerfile
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
```
BuildKit cache mount giữ module cache và build cache giữa các lần build, kể cả khi layer bị build lại. Cache này không nằm trong image. Trên Jenkins (GĐ4) nó giúp build nhanh hơn rất nhiều.

```dockerfile
CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
go build -trimpath -ldflags="-s -w" -o /out/catalog .
```
| Flag | Vì sao |
|---|---|
| `CGO_ENABLED=0` | Binary tĩnh, không phụ thuộc glibc/musl → chạy được trên image gần như rỗng |
| `GOOS/GOARCH` | **Cross-compile.** Mac M1/M2 là `arm64`, còn EC2 t3 là `amd64`. Go tự cross-compile nên không cần giả lập QEMU (vốn chậm) |
| `-trimpath` | Bỏ đường dẫn máy build ra khỏi binary (build tái lập được, không lộ thông tin máy) |
| `-ldflags="-s -w"` | Bỏ debug symbol → binary nhỏ hơn khoảng 30% |

### Stage 2 – runtime
```dockerfile
FROM gcr.io/distroless/static-debian12:nonroot
```
**Distroless** chỉ có CA certs, tzdata và `/etc/passwd`, khoảng 2 MB. Không có shell, không có package manager.

| | `alpine` | `distroless/static` | `scratch` |
|---|---|---|---|
| Kích thước | ~8 MB | ~2 MB | 0 |
| Có shell để debug | ✅ | ❌ | ❌ |
| CA certs, user nonroot | phải tự thêm | có sẵn | phải tự thêm |
| Số CVE scanner báo | thấp | rất thấp | 0 |

Production thường chọn distroless: ít thứ để tấn công, scanner (Trivy ở GĐ4) ít báo lỗi.
**Đánh đổi:** không `docker exec ... sh` vào được. Debug bằng `kubectl debug` với ephemeral container (sẽ học ở GĐ3).

```dockerfile
USER nonroot:nonroot
```
Container chạy root thì nếu app bị khai thác lỗ hổng, attacker có root trong container, và gần hơn một bước để thoát ra host. Image `:nonroot` có sẵn user UID 65532. Ở GĐ3, K8s sẽ ép thêm `runAsNonRoot: true`.

```dockerfile
ENTRYPOINT ["/app/catalog"]
```
Dạng **exec (JSON array)**: binary là PID 1 nên nhận được SIGTERM khi `docker stop`/K8s xoá pod → shutdown sạch.
Dạng shell (`ENTRYPOINT /app/catalog`) bọc app trong `sh -c`, signal không tới app, phải chờ 10 s rồi bị SIGKILL. Image distroless cũng không có `sh` nên dạng này sẽ lỗi.

### `.dockerignore`
Build context là toàn bộ thư mục được gửi cho Docker daemon. Loại bỏ test, docs, binary cũ để:
1. Build nhanh hơn (gửi ít dữ liệu hơn).
2. Sửa README không làm vỡ cache của `COPY . .`.
3. Không vô tình copy secret (`.env`) vào image.

---

## 3. Thực hành

> Mở Docker Desktop trước (daemon đang tắt).

```bash
cd src/catalog

# 1. Build cho máy local
docker build -t retail-catalog:dev .

# 2. Kiểm tra kích thước (kỳ vọng: khoảng 20–30 MB)
docker images retail-catalog
docker image inspect retail-catalog:dev --format '{{.Architecture}} user={{.Config.User}}'

# 3. Chạy thử không cần DB?
docker run --rm -p 8081:8080 retail-catalog:dev
```
Bước 3 **sẽ lỗi**. Đây là cố ý: provider mặc định là `in-memory` (SQLite cần CGO). Đọc log để thấy lỗi, rồi chạy kèm MariaDB:

```bash
docker network create retail-test

docker run -d --name catalog-db --network retail-test \
  -e MARIADB_DATABASE=catalogdb -e MARIADB_USER=catalog_user \
  -e MARIADB_PASSWORD=secret -e MARIADB_ROOT_PASSWORD=rootsecret \
  mariadb:10.11

# đợi khoảng 15 s cho DB khởi động: docker logs -f catalog-db

docker run -d --name catalog --network retail-test -p 8081:8080 \
  -e RETAIL_CATALOG_PERSISTENCE_PROVIDER=mysql \
  -e RETAIL_CATALOG_PERSISTENCE_ENDPOINT=catalog-db:3306 \
  -e RETAIL_CATALOG_PERSISTENCE_PASSWORD=secret \
  retail-catalog:dev

curl -s localhost:8081/health
curl -s localhost:8081/catalog/products | head -c 300
```

**Lưu ý:** container `catalog` gọi DB bằng tên `catalog-db` là nhờ **DNS nội bộ của user-defined network**. Network `bridge` mặc định không có tính năng này. docker-compose (bước sau) tự tạo network như vậy cho bạn.

Các endpoint khác: `/catalog/products/:id`, `/catalog/tags`, `/catalog/size`, `/topology`.

```bash
# 4. Build cho EC2 (amd64), để dùng từ GĐ2 trở đi
docker buildx build --platform linux/amd64 -t retail-catalog:dev-amd64 --load .

# 5. Dọn dẹp
docker rm -f catalog catalog-db && docker network rm retail-test
```

---

## 4. Kiểm tra bản thân (checklist kỹ thuật)
- [ ] Image < 40 MB, `User` = `nonroot:nonroot`
- [ ] Sửa 1 dòng trong `main.go` rồi build lại → bước `go mod download` hiện `CACHED`
- [ ] Sửa `README.md` rồi build lại → toàn bộ các bước đều `CACHED`
- [ ] `docker stop catalog` dừng ngay (dưới 1 s), không phải chờ 10 s
- [ ] So sánh với `Dockerfile.upstream`: bản gốc dùng Amazon Linux đầy đủ, nặng hơn nhiều, nhưng có `curl` để healthcheck

## 5. Hệ quả cần nhớ cho bước sau
- Image không có `curl`/`wget` → **không viết được `healthcheck` trong compose** cho catalog. Ở bước compose, các service phụ thuộc catalog dùng `condition: service_started`.
- Ở GĐ3, K8s probe dạng `httpGet` do kubelet gọi từ bên ngoài container, không cần tool trong image, nên không còn vấn đề này.

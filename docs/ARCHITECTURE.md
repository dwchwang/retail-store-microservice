# Kiến trúc Retail Store Sample App

> Tóm tắt từ source upstream `aws-containers/retail-store-sample-app` (commit `d7a380b`, 25/09/2026).
> Mục đích: đủ thông tin để **triển khai** mà không cần đọc code service.

## 1. Sơ đồ tổng quan

```
                         ┌──────────────┐
        Người dùng ────▶ │ Nginx / Ingress │  (GĐ1: Nginx, GĐ3: Ingress)
                         └──────┬───────┘
                                │ :8080
                         ┌──────▼───────┐
                         │      UI      │  Java 21 / Spring Boot 3.5
                         └──┬───┬───┬───┘
            ┌───────────────┘   │   └────────────────┐
            │ HTTP              │ HTTP               │ HTTP
     ┌──────▼─────┐     ┌───────▼────┐       ┌───────▼──────┐        ┌────────────┐
     │  Catalog   │     │    Cart    │       │   Checkout   │──HTTP─▶│   Orders   │
     │  Go 1.25   │     │  Java 21   │       │ Node 20/Nest │        │  Java 21   │
     └──────┬─────┘     └──────┬─────┘       └───────┬──────┘        └──┬─────┬───┘
            │                  │                     │                  │     │
     ┌──────▼─────┐   ┌────────▼───────┐     ┌───────▼──────┐   ┌───────▼┐  ┌─▼────────┐
     │  MariaDB   │   │ DynamoDB Local │     │    Redis     │   │Postgres│  │ RabbitMQ │
     │  (MySQL)   │   │                │     │              │   │        │  │          │
     └────────────┘   └────────────────┘     └──────────────┘   └────────┘  └──────────┘
```

- **Chỉ UI có cổng ra ngoài.** 4 backend và 5 data store đều là traffic nội bộ.
- UI gọi Orders trực tiếp để xem đơn hàng. Luồng đặt hàng đi qua Checkout, rồi Checkout gọi Orders.
- Orders publish event vào RabbitMQ (fanout exchange `orders-exchange` → queue `orders-orders-queue`) và tự consume lại. Không có service nào khác đọc queue này.
- **Recommendations** chỉ có OpenAPI spec, *chưa được implement*. UI dùng stub có sẵn bên trong, nên không cần deploy.

## 2. Bảng service

| Service | Ngôn ngữ / Runtime | Build tool | Port | Health check | Metrics (Prometheus) |
|---|---|---|---|---|---|
| ui | Java 21, Spring Boot 3.5 | Maven (`./mvnw`) | 8080 | `/actuator/health` | `/actuator/prometheus` |
| catalog | Go 1.25 (Gin + GORM) | `go build` | 8080 | `/health` | `/metrics` |
| cart | Java 21, Spring Boot 3.5 | Maven (`./mvnw`) | 8080 | `/actuator/health` | `/actuator/prometheus` |
| orders | Java 21, Spring Boot 3.5 | Maven (`./mvnw`) | 8080 | `/actuator/health` | `/actuator/prometheus` |
| checkout | Node 20, NestJS | Yarn | 8080 | `/health` | `/metrics` |

Mọi service đều nghe ở **8080**. Vì vậy trong compose/K8s, các service phân biệt nhau bằng **tên service (DNS)**, không bằng port.

## 3. Data store

| Store | Dùng cho | Image tham khảo | Khởi tạo schema |
|---|---|---|---|
| MariaDB 10.9 (MySQL) | catalog | `mariadb:10.9` | Catalog tự `AutoMigrate` và seed sản phẩm khi khởi động |
| DynamoDB Local | cart | `amazon/dynamodb-local` | Cart tự tạo bảng nếu `..._CREATE_TABLE=true` |
| PostgreSQL 16 | orders | `postgres:16` | Orders dùng Flyway (`V1__Initial.sql`), tự migrate |
| RabbitMQ 3 | orders (event) | `rabbitmq:3-management` | Orders tự khai báo exchange/queue |
| Redis 6+ | checkout (session checkout) | `redis:6-alpine` | Không cần |

Không có service nào cần chạy migration thủ công. Chỉ cần DB đã sẵn sàng **trước khi** app start, hoặc app restart được cho tới khi DB sẵn sàng.

> **Chưa có MongoDB.** Cart chỉ hỗ trợ `in-memory` hoặc `dynamodb`, nên dùng DynamoDB Local (không cần AWS thật; access key giả là đủ).

## 4. Biến môi trường cần set khi triển khai

Các biến tùy chọn (chat bot, theme, search…) để mặc định. Bảng dưới chỉ liệt kê những biến bắt buộc để chạy với data store thật.

### ui
| Biến | Giá trị ví dụ |
|---|---|
| `RETAIL_UI_ENDPOINTS_CATALOG` | `http://catalog:8080` |
| `RETAIL_UI_ENDPOINTS_CARTS` | `http://cart:8080` |
| `RETAIL_UI_ENDPOINTS_ORDERS` | `http://orders:8080` |
| `RETAIL_UI_ENDPOINTS_CHECKOUT` | `http://checkout:8080` |

Nếu thiếu một endpoint, UI sẽ **tự dùng mock** và không báo lỗi. Đây là bẫy hay gặp: web vẫn chạy nhưng không gọi backend thật.

### catalog
| Biến | Giá trị ví dụ |
|---|---|
| `RETAIL_CATALOG_PERSISTENCE_PROVIDER` | `mysql` |
| `RETAIL_CATALOG_PERSISTENCE_ENDPOINT` | `catalog-db:3306` |
| `RETAIL_CATALOG_PERSISTENCE_DB_NAME` | `catalogdb` |
| `RETAIL_CATALOG_PERSISTENCE_USER` | `catalog_user` |
| `RETAIL_CATALOG_PERSISTENCE_PASSWORD` | *(secret)* |

### cart
| Biến | Giá trị ví dụ |
|---|---|
| `RETAIL_CART_PERSISTENCE_PROVIDER` | `dynamodb` |
| `RETAIL_CART_PERSISTENCE_DYNAMODB_ENDPOINT` | `http://cart-db:8000` |
| `RETAIL_CART_PERSISTENCE_DYNAMODB_CREATE_TABLE` | `true` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | giá trị giả bất kỳ |
| `AWS_REGION` | `us-east-1` (SDK cần có region) |

### orders
| Biến | Giá trị ví dụ |
|---|---|
| `RETAIL_ORDERS_PERSISTENCE_PROVIDER` | `postgres` (README upstream ghi nhầm thành `RETAIL_CHECKOUT_...`) |
| `RETAIL_ORDERS_PERSISTENCE_ENDPOINT` | `orders-db:5432` |
| `RETAIL_ORDERS_PERSISTENCE_NAME` | `orders` |
| `RETAIL_ORDERS_PERSISTENCE_USERNAME` | `orders_user` |
| `RETAIL_ORDERS_PERSISTENCE_PASSWORD` | *(secret)* |
| `RETAIL_ORDERS_MESSAGING_PROVIDER` | `rabbitmq` |
| `RETAIL_ORDERS_MESSAGING_RABBITMQ_ADDRESSES` | `rabbitmq:5672` |
| `RETAIL_ORDERS_MESSAGING_RABBITMQ_USERNAME` | `orders` |
| `RETAIL_ORDERS_MESSAGING_RABBITMQ_PASSWORD` | *(secret)* |

### checkout
| Biến | Giá trị ví dụ |
|---|---|
| `RETAIL_CHECKOUT_PERSISTENCE_PROVIDER` | `redis` |
| `RETAIL_CHECKOUT_PERSISTENCE_REDIS_URL` | `redis://checkout-redis:6379` |
| `RETAIL_CHECKOUT_ENDPOINTS_ORDERS` | `http://orders:8080` (thiếu → mock, đơn **không** vào Postgres) |

### Biến chung cho Java
- `JAVA_OPTS=-XX:MaxRAMPercentage=75.0`: JVM tự tính heap theo memory limit của container.
- `SPRING_PROFILES_ACTIVE=prod`: bật graceful shutdown và cache static.

### Tracing (GĐ5, tùy chọn)
`OTEL_SDK_DISABLED=false`, `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318`, `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`, `OTEL_SERVICE_NAME=<tên service>`.

## 5. Thứ tự khởi động (dependency)

```
mariadb ─▶ catalog ─┐
cart-db ─▶ cart ────┤
postgres + rabbitmq ─▶ orders ─▶ checkout (+ redis) ─┤
                                                     └─▶ ui ─▶ nginx
```

UI vẫn start được khi backend chưa sẵn sàng, nhưng request sẽ lỗi. Các backend Java sẽ crash nếu không kết nối được DB, nên cần `depends_on: condition: service_healthy` (compose) hoặc restart/probe (K8s).

## 6. Ước lượng tài nguyên (để sizing EC2)

| Thành phần | RAM gợi ý (limit) | Ghi chú |
|---|---|---|
| ui, cart, orders (JVM) | 512Mi mỗi cái | Java là phần tốn RAM nhất |
| catalog (Go) | 128Mi | rất nhẹ |
| checkout (Node) | 256Mi | |
| MariaDB, Postgres | 256–512Mi mỗi cái | |
| RabbitMQ | 256–512Mi | |
| DynamoDB Local | 256–512Mi | chạy JVM |
| Redis | 64–128Mi | |

Tổng app + data khoảng **3–4 GiB**, chưa tính monitoring (kube-prometheus-stack + Loki thêm khoảng 2–3 GiB) và overhead của RKE2/Longhorn.

## 7. Những thứ bỏ qua

| Thành phần upstream | Lý do bỏ |
|---|---|
| OpenSearch (search catalog) | Tắt mặc định, tốn khoảng 1 GiB RAM, không cần cho luồng đặt hàng |
| Chat bot (Bedrock/OpenAI) | Tắt mặc định, không liên quan DevOps |
| Recommendations | Chưa được implement |
| `src/*/chart/`, helmfile, Tiltfile | Đã xoá; Helm chart sẽ tự viết ở GĐ3 |
| `src/*/Dockerfile`, `src/*/docker-compose.yml`, `src/app/` | Giữ để tham khảo; tự viết bản riêng rồi so sánh |
| `src/load-generator` | Giữ lại, dùng ở GĐ5 |

## 8. Smoke test end-to-end

1. Mở UI → thấy danh sách sản phẩm (catalog thật, không phải mock).
2. Thêm vào giỏ → reload trang vẫn còn (cart → DynamoDB Local).
3. Checkout → đặt hàng thành công.
4. Kiểm chứng:
   ```
   psql -U orders_user -d orders -c 'select * from orders;'
   ```
   có bản ghi; RabbitMQ management UI (`:15672`) thấy message đi qua `orders-exchange`.

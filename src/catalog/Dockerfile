# syntax=docker/dockerfile:1

ARG GO_VERSION=1.25

# ---------- Stage 1: build ----------
FROM golang:${GO_VERSION}-alpine AS build
WORKDIR /src

# Copy file khai báo dependency trước để tận dụng layer cache
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .

# TARGETOS/TARGETARCH do BuildKit tự điền theo --platform
ARG TARGETOS
ARG TARGETARCH
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/catalog .

# ---------- Stage 2: runtime ----------
FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /app

COPY --from=build /out/catalog /app/catalog

ENV GIN_MODE=release \
    PORT=8080
EXPOSE 8080

USER nonroot:nonroot
ENTRYPOINT ["/app/catalog"]

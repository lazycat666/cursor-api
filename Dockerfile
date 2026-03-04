# 定义构建参数
ARG TARGETARCH
ARG BUILD_PREVIEW=false
ARG BUILD_COMPAT=false

# ==================== 构建阶段 ====================
FROM --platform=linux/${TARGETARCH} rustlang/rust:nightly-trixie-slim AS builder

ARG TARGETARCH
ARG BUILD_PREVIEW
ARG BUILD_COMPAT

WORKDIR /build

# 安装构建依赖及 Rust musl 工具链
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc nodejs npm lld musl-tools && \
    rm -rf /var/lib/apt/lists/* && \
    case "$TARGETARCH" in \
        amd64) rustup target add x86_64-unknown-linux-musl ;; \
        arm64) rustup target add aarch64-unknown-linux-musl ;; \
        *) echo "Unsupported architecture for rustup: $TARGETARCH" && exit 1 ;; \
    esac

COPY . .

# 复制 frontend.zip
COPY frontend.zip /build/

# 根据构建选项，设置编译参数并构建项目
RUN \
    # 根据架构设置编译目标
    case "$TARGETARCH" in \
        amd64) \
            TARGET_TRIPLE="x86_64-unknown-linux-musl" ;; \
        arm64) \
            TARGET_TRIPLE="aarch64-unknown-linux-musl" ;; \
        *) echo "Unsupported architecture: $TARGETARCH" && exit 1 ;; \
    esac && \
    \
    # 组合 cargo features
    FEATURES="" && \
    if [ "$BUILD_PREVIEW" = "true" ]; then FEATURES="$FEATURES __preview_locked"; fi && \
    if [ "$BUILD_COMPAT" = "true" ]; then FEATURES="$FEATURES __compat"; fi && \
    FEATURES=$(echo "$FEATURES" | xargs) && \
    \
    # 准备 RUSTFLAGS，使用通用 CPU 目标以获得最大兼容性
    RUSTFLAGS_BASE="-C link-arg=-s -C link-arg=-fuse-ld=lld -C target-feature=+crt-static -A unused" && \
    export RUSTFLAGS="$RUSTFLAGS_BASE" && \
    \
    # 执行构建（使用通用 CPU 目标以获得最大兼容性）
    # -C link-arg=-s: 移除符号表以减小体积
    # -C target-feature=+crt-static: 静态链接 C 运行时
    # -A unused: 允许未使用的代码
    if [ -n "$FEATURES" ]; then \
        cargo build --bin cursor-api --release --target=$TARGET_TRIPLE --features "$FEATURES"; \
    else \
        cargo build --bin cursor-api --release --target=$TARGET_TRIPLE; \
    fi && \
    \
    mkdir -p /app && \
    cp target/$TARGET_TRIPLE/release/cursor-api /app/ && \
    if [ -f /build/frontend.zip ]; then cp /build/frontend.zip /app/; fi && \
    if [ -f /build/static/route_registry.json ]; then cp /build/static/route_registry.json /app/; fi

# ==================== 运行阶段 ====================
FROM alpine:latest

# 安装必要的运行时依赖
RUN apk add --no-cache ca-certificates tzdata && \
    adduser -D -u 1001 appuser

# 从构建阶段复制二进制文件
COPY --from=builder --chown=1001:1001 --chmod=0700 /app /app

WORKDIR /app

ENV PORT=3000
EXPOSE ${PORT}

# 使用非 root 用户运行，增强安全性
USER 1001

ENTRYPOINT ["/app/cursor-api"]

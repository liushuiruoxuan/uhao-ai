ARG NPM_REGISTRY=https://registry.npmmirror.com
ARG GOPROXY_URL=https://goproxy.cn,https://goproxy.io,direct

FROM oven/bun:1 AS builder

WORKDIR /build
ENV BUN_INSTALL_REGISTRY=${NPM_REGISTRY}
COPY web/default/package.json .
COPY web/default/bun.lock .
RUN --mount=type=cache,target=/root/.bun/install/cache \
    bun install
COPY ./web/default .
COPY ./VERSION .
RUN DISABLE_ESLINT_PLUGIN='true' VITE_REACT_APP_VERSION=$(cat VERSION) bun run build

FROM oven/bun:1 AS builder-classic

WORKDIR /build
ENV BUN_INSTALL_REGISTRY=${NPM_REGISTRY}
COPY web/classic/package.json .
COPY web/classic/bun.lock .
RUN --mount=type=cache,target=/root/.bun/install/cache \
    bun install
COPY ./web/classic .
COPY ./VERSION .
RUN VITE_REACT_APP_VERSION=$(cat VERSION) bun run build

FROM golang:1.26.1-alpine AS builder2
ENV GO111MODULE=on CGO_ENABLED=0 GOPROXY=${GOPROXY_URL}

ARG TARGETOS
ARG TARGETARCH
ENV GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH:-amd64}
ENV GOEXPERIMENT=greenteagc

WORKDIR /build

ADD go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .
COPY --from=builder /build/dist ./web/default/dist
COPY --from=builder-classic /build/dist ./web/classic/dist
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    go build -ldflags "-s -w -X 'github.com/QuantumNous/uhao-api/common.Version=$(cat VERSION)'" -o uhao-api

FROM debian:bookworm-slim

RUN sed -i 's|deb.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata libasan8 wget \
    && rm -rf /var/lib/apt/lists/* \
    && update-ca-certificates

COPY --from=builder2 /build/uhao-api /
COPY LICENSE NOTICE THIRD-PARTY-LICENSES.md /licenses/
EXPOSE 3000
WORKDIR /data
ENTRYPOINT ["/uhao-api"]

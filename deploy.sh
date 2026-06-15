#!/usr/bin/env bash
# uhao-api 一键部署脚本
# 用法: ./deploy.sh [--fresh] [--sync-only] [--no-build]
#
# 选项:
#   --fresh      清空数据库卷，全新部署
#   --sync-only  只同步代码，不构建不重启
#   --no-build   跳过构建，直接启动（使用已有镜像）

set -euo pipefail

# ─── 颜色 ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─── 参数解析 ─────────────────────────────────────────────
FRESH=false
SYNC_ONLY=false
NO_BUILD=false

for arg in "$@"; do
  case "$arg" in
    --fresh)      FRESH=true ;;
    --sync-only)  SYNC_ONLY=true ;;
    --no-build)   NO_BUILD=true ;;
    --help|-h)
      echo "用法: ./deploy.sh [--fresh] [--sync-only] [--no-build]"
      echo ""
      echo "选项:"
      echo "  --fresh      清空数据库卷，全新部署"
      echo "  --sync-only  只同步代码，不构建不重启"
      echo "  --no-build   跳过构建，直接启动（使用已有镜像）"
      exit 0
      ;;
    *)
      err "未知参数: $arg"
      exit 1
      ;;
  esac
done

# ─── 加载配置 ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.production"

if [[ ! -f "$ENV_FILE" ]]; then
  err "未找到 .env.production，请从模板创建"
  exit 1
fi

# shellcheck source=.env.production
source "$ENV_FILE"

DEPLOY_HOST="${DEPLOY_HOST:?需要设置 DEPLOY_HOST}"
DEPLOY_USER="${DEPLOY_USER:?需要设置 DEPLOY_USER}"
DEPLOY_PASSWORD="${DEPLOY_PASSWORD:?需要设置 DEPLOY_PASSWORD}"
DEPLOY_PATH="${DEPLOY_PATH:?需要设置 DEPLOY_PATH}"
DEPLOY_PORT="${DEPLOY_PORT:-22}"

SSH_CMD="sshpass -p '${DEPLOY_PASSWORD}' ssh -o StrictHostKeyChecking=no -p ${DEPLOY_PORT} ${DEPLOY_USER}@${DEPLOY_HOST}"
RSYNC_SSH="sshpass -p '${DEPLOY_PASSWORD}' ssh -o StrictHostKeyChecking=no -p ${DEPLOY_PORT}"

COMPOSE_FILE="docker-compose.mysql.yml"

# ─── 前置检查 ─────────────────────────────────────────────
info "检查本地工具..."
for cmd in sshpass rsync; do
  if ! command -v "$cmd" &>/dev/null; then
    err "缺少 $cmd，请安装: brew install $cmd"
    exit 1
  fi
done
ok "本地工具就绪"

# ─── 检查服务器连接 ───────────────────────────────────────
info "连接服务器 ${DEPLOY_HOST}..."
if ! eval "$SSH_CMD 'echo ok'" &>/dev/null; then
  err "无法连接服务器 ${DEPLOY_HOST}"
  exit 1
fi
ok "服务器连接成功"

# ─── 检查现有部署 ─────────────────────────────────────────
info "检查现有部署..."
EXISTING=$(eval "$SSH_CMD 'docker ps -a --filter name=uhao-api --format {{.Names}} 2>/dev/null'" || true)
if [[ -n "$EXISTING" ]]; then
  warn "发现现有容器: ${EXISTING}"
fi

# ─── 停止现有容器 ─────────────────────────────────────────
if [[ "$SYNC_ONLY" == "false" ]]; then
  info "停止现有容器..."
  DOWN_CMD="cd ${DEPLOY_PATH} && docker compose -f ${COMPOSE_FILE} down"
  if [[ "$FRESH" == "true" ]]; then
    warn "使用 --fresh 模式，将清空数据库卷！"
    DOWN_CMD="cd ${DEPLOY_PATH} && docker compose -f ${COMPOSE_FILE} down -v"
  fi
  eval "$SSH_CMD '${DOWN_CMD}'" 2>&1 | sed 's/^/  /'
  ok "容器已停止"
fi

# ─── 同步代码 ─────────────────────────────────────────────
info "同步代码到服务器..."
rsync -avz --quiet \
  -e "$RSYNC_SSH" \
  --exclude '.git' \
  --exclude 'node_modules' \
  --exclude '.DS_Store' \
  --exclude 'data/' \
  --exclude 'logs/' \
  --exclude 'docker-compose.dev.yml' \
  --exclude '.claude/' \
  --exclude '.cursor/' \
  --exclude 'plans/' \
  "${SCRIPT_DIR}/" \
  "${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}/"
ok "代码同步完成"

# ─── 同步环境变量 ─────────────────────────────────────────
info "同步环境变量配置..."
eval "$SSH_CMD 'cp ${DEPLOY_PATH}/.env.production ${DEPLOY_PATH}/.env'" 2>/dev/null || \
  warn ".env.production 已随 rsync 同步，跳过复制"

if [[ "$SYNC_ONLY" == "true" ]]; then
  ok "同步完成（--sync-only 模式，跳过构建和启动）"
  exit 0
fi

# ─── 构建并启动 ───────────────────────────────────────────
if [[ "$NO_BUILD" == "true" ]]; then
  info "启动容器（--no-build，跳过构建）..."
  eval "$SSH_CMD 'cd ${DEPLOY_PATH} && docker compose -f ${COMPOSE_FILE} --env-file .env up -d'" 2>&1 | sed 's/^/  /'
else
  info "构建并启动容器（首次约 5-10 分钟）..."
  eval "$SSH_CMD 'cd ${DEPLOY_PATH} && docker compose -f ${COMPOSE_FILE} --env-file .env up -d --build'" 2>&1 | sed 's/^/  /'
fi
ok "容器已启动"

# ─── 等待健康检查 ─────────────────────────────────────────
info "等待服务健康检查..."
for i in $(seq 1 30); do
  STATUS=$(eval "$SSH_CMD 'curl -s -o /dev/null -w %{http_code} http://localhost/api/status 2>/dev/null'" || echo "000")
  if [[ "$STATUS" == "200" ]]; then
    ok "API 健康检查通过 (HTTP ${STATUS})"
    break
  fi
  if [[ $i -eq 30 ]]; then
    warn "健康检查超时，请手动检查: curl http://${DEPLOY_HOST}/api/status"
  fi
  sleep 5
done

# ─── 部署结果 ─────────────────────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  部署完成！${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo -e "  地址: ${CYAN}http://${DEPLOY_HOST}${NC}"
echo -e "  配置: ${CYAN}${DEPLOY_PATH}/${COMPOSE_FILE}${NC}"
echo ""

# 显示容器状态
info "容器状态:"
eval "$SSH_CMD 'docker ps --filter name=uhao-api --filter name=mysql --filter name=redis --format \"table {{.Names}}\t{{.Status}}\t{{.Ports}}\"'" 2>/dev/null || true

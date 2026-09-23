#!/usr/bin/env bash
# =============================================================================
# Y2A-Auto CodeSpaces 云发布管线: 测试 → 打包 → GitHub Release
#
# 为什么在 Codespaces: GitHub Actions 只保留 lint.yml(极轻量), 重活
# (pytest 全量 + docker build + 产物上传)全部在临时 codespace 构建机执行,
# 省 Actions 分钟。用完立刻 gh codespace stop/delete 省 core-hours 额度。
#
# 用法(codespace 内, 仓库根或任意目录):
#   TAG=v4.10.2-fork.1 bash codespace/build-and-publish.sh
#
# 可选环境变量:
#   REPO=DerekEXS/Y2A-Auto   目标仓库
#   SKIP_TESTS=1             跳过 pytest+js 测试(紧急出包)
#   SKIP_IMAGE=1             跳过 docker build(只发源码归档)
#
# 纪律(codespaces skill): 建机带 --idle-timeout 15m; 跑完先 stop,
# 确认产物无误后 delete(停止的机器照样占存储额度)。
# =============================================================================
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REPO="${REPO:-DerekEXS/Y2A-Auto}"
SHA="$(git rev-parse HEAD)"
SHORT="$(git rev-parse --short HEAD)"
TAG="${TAG:-}"
[ -n "$TAG" ] || { echo "必须显式给 TAG (例: TAG=v4.10.2-fork.1), 防呆避免误发"; exit 1; }
OUT="${OUT:-/tmp/release-artifacts}"
log(){ printf '\n[release-pipeline] %s\n' "$*"; }

log "REPO=$REPO TAG=$TAG SHA=$SHORT"

# ---------- 0. 预检 ----------
# Codespaces 的 GITHUB_TOKEN 只注入登录 shell; 经 `gh codespace ssh -- cmd`(非登录)
# 进来时 env 里没有。这里兜底 source profile, 仍无则提示用 bash -lc 调本脚本。
if [ -z "${GITHUB_TOKEN:-}${GH_TOKEN:-}" ]; then
  for f in "$HOME/.profile" /etc/profile.d/codespaces*.sh; do
    [ -r "$f" ] && . "$f" 2>/dev/null || true
  done
fi
gh auth status >/dev/null || { echo "gh 未登录(GITHUB_TOKEN 缺失?)。请用: bash -lc 'TAG=... bash codespace/build-and-publish.sh'"; exit 1; }
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  echo "TAG $TAG 已存在 Release, 中止(避免重复上传)"; exit 1
fi
mkdir -p "$OUT"; rm -rf "$OUT"/*

# ---------- 1. 依赖(postCreateCommand 已装则秒过) ----------
if ! python3 -c 'import pytest, flask' >/dev/null 2>&1; then
  log "installing deps (~2-4min)"
  python3 -m pip install --quiet --upgrade pip
  python3 -m pip install --quiet -r requirements.txt pytest
fi

# ---------- 2. 测试 ----------
TEST_SUMMARY="skipped"
if [ "${SKIP_TESTS:-0}" != "1" ]; then
  log "running pytest (全量)"
  python3 -m pytest tests/ -q --maxfail=10 2>&1 | tee /tmp/pytest.log
  TEST_SUMMARY="$(grep -E '^[0-9]+ (passed|failed)|passed|failed' /tmp/pytest.log | tail -1)"
  log "pytest done: $TEST_SUMMARY"
  if command -v node >/dev/null 2>&1 && ls tests/js/*.js >/dev/null 2>&1; then
    for f in tests/js/*.js; do log "node $f"; node "$f"; done
  fi
fi

# ---------- 3. Docker 镜像构建+导出 ----------
if [ "${SKIP_IMAGE:-0}" != "1" ]; then
  command -v docker >/dev/null || { echo "docker 不可用(检查 devcontainer 的 docker-in-docker feature)"; exit 1; }
  log "docker build -t y2a-auto:$TAG ."
  docker build -q -t "y2a-auto:$TAG" .
  log "docker save | gzip → 镜像归档(数分钟)"
  docker save "y2a-auto:$TAG" | gzip -1 > "$OUT/y2a-auto-${TAG}-image.tar.gz"
fi

# ---------- 4. 源码归档 ----------
git archive --format=tar.gz --prefix="y2a-auto-${TAG}/" -o "$OUT/y2a-auto-${TAG}-src.tar.gz" HEAD
log "artifacts:"; ls -la "$OUT"

# ---------- 5. Release notes ----------
PREV_TAG="$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || true)"
{
  echo "## Y2A-Auto fork release $TAG"
  echo ""
  echo "- commit: \`$SHORT\` $(git log -1 --format=%s)"
  echo "- tests: $TEST_SUMMARY"
  echo "- built: $(date -u '+%F %T') UTC @ Codespaces"
  if [ -n "$PREV_TAG" ]; then
    echo "- since \`$PREV_TAG\`:"
    git log --oneline "$PREV_TAG"..HEAD | sed 's/^/  - /'
  fi
  echo ""
  echo "### 产物"
  echo "- \`y2a-auto-${TAG}-image.tar.gz\` → 本地 \`gunzip -c | docker load\` 直接部署"
  echo "- \`y2a-auto-${TAG}-src.tar.gz\` → 源码快照"
  echo ""
  echo "> 私有仓产物别用浏览器 URL(恒 404), 用: \`gh release download $TAG -R $REPO -p '*.tar.gz'\`"
} > /tmp/release-notes.md

# ---------- 6. 创建 Release ----------
log "gh release create $TAG"
# shellcheck disable=SC2046
gh release create "$TAG" -R "$REPO" \
  --target "$SHA" \
  --title "$TAG" \
  --notes-file /tmp/release-notes.md \
  "$OUT"/*.tar.gz

log "DONE → https://github.com/$REPO/releases/tag/$TAG"

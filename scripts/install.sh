#!/usr/bin/env bash
#
# RelayDeck Lite one-line installer.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/shuichang/relaydeck-lite/main/scripts/install.sh)
#   bash <(curl -fsSL https://raw.githubusercontent.com/shuichang/relaydeck-lite/main/scripts/install.sh) --no-menu
#

set -Eeuo pipefail

REPO="${RELAYDECK_REPO:-shuichang/relaydeck-lite}"
API_BASE="https://api.github.com/repos/${REPO}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}"
VERSION="${RELAYDECK_VERSION:-latest}"
NO_MENU=0
NO_START=0
INSTALL_DIR="${RELAYDECK_INSTALL_DIR:-/usr/local/bin}"
CONFIG_DIR="${RELAYDECK_CONFIG_DIR:-/etc/relaydeck-lite}"
DATA_DIR="${RELAYDECK_DATA_DIR:-/var/lib/relaydeck-lite}"
SOCKET_PATH="${RELAYDECK_SOCKET:-/run/relaydeck-lite.sock}"

log() {
  printf '[relaydeck-lite] %s\n' "$*"
}

die() {
  printf '[relaydeck-lite] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
RelayDeck Lite 安装脚本

用法：
  bash install.sh [选项]

选项：
  --version VERSION   安装指定版本，例如 v0.1.0
  --no-menu           安装后不进入交互菜单
  --no-start          安装服务但不立即启动
  -h, --help          显示帮助

环境变量：
  RELAYDECK_VERSION       默认版本，默认 latest
  RELAYDECK_INSTALL_DIR   二进制目录，默认 /usr/local/bin
  RELAYDECK_CONFIG_DIR    配置目录，默认 /etc/relaydeck-lite
  RELAYDECK_DATA_DIR      数据目录，默认 /var/lib/relaydeck-lite
  RELAYDECK_SOCKET        控制 socket，默认 /run/relaydeck-lite.sock
  RELAYDECK_INSTALL_NO_MENU=1  安装后不进入菜单
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || die "--version 缺少参数"
      VERSION="$2"
      shift 2
      ;;
    --no-menu)
      NO_MENU=1
      shift
      ;;
    --no-start)
      NO_START=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac
done

if [ "${RELAYDECK_INSTALL_NO_MENU:-0}" = "1" ]; then
  NO_MENU=1
fi

[ "$(uname -s)" = "Linux" ] || die "仅支持 Linux"
[ "$(id -u)" -eq 0 ] || die "请使用 root 运行，或通过 sudo 执行此脚本"
command -v curl >/dev/null 2>&1 || die "缺少 curl"
command -v tar >/dev/null 2>&1 || die "缺少 tar"
command -v sha256sum >/dev/null 2>&1 || die "缺少 sha256sum"

case "$(uname -m)" in
  x86_64|amd64)
    ARCH="amd64"
    ;;
  *)
    die "当前 Release 暂只提供 x86_64/amd64，检测到：$(uname -m)"
    ;;
esac

if [ -f /etc/alpine-release ] ||
  (command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl) ||
  compgen -G '/lib/ld-musl-*.so.1' >/dev/null 2>&1; then
  LIBC="musl"
else
  LIBC="gnu"
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/relaydeck-lite-install.XXXXXX")"
trap 'rm -rf -- "$TMP_DIR"' EXIT

download() {
  curl -fsSL --retry 3 --connect-timeout 15 --max-time 180 \
    "$1" -o "$2"
}

if [ "$VERSION" = "latest" ]; then
  log "正在获取最新版本..."
  TAG="$(
    curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 \
      -H 'Accept: application/vnd.github+json' \
      "${API_BASE}/releases/latest" |
      sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' |
      head -n 1
  )"
  [ -n "$TAG" ] || die "无法获取最新 Release，请使用 --version v0.1.0"
else
  TAG="v${VERSION#v}"
fi

VERSION_NUMBER="${TAG#v}"
ASSET="relaydeck-lite_${VERSION_NUMBER}_linux_${ARCH}_${LIBC}.tar.gz"
RELEASE_BASE="https://github.com/${REPO}/releases/download/${TAG}"
CHECKSUMS="${TMP_DIR}/checksums.txt"
ARCHIVE="${TMP_DIR}/${ASSET}"

log "系统：$(if [ "$LIBC" = musl ]; then printf Alpine/musl; else printf Debian/glibc; fi)"
log "版本：${TAG}"
log "下载：${ASSET}"
download "${RELEASE_BASE}/checksums.txt" "$CHECKSUMS"
download "${RELEASE_BASE}/${ASSET}" "$ARCHIVE"

EXPECTED_SHA="$(
  awk -v asset="$ASSET" '$2 == asset { print $1; exit }' "$CHECKSUMS"
)"
[ -n "$EXPECTED_SHA" ] || die "checksums.txt 中没有找到 ${ASSET}"
printf '%s  %s\n' "$EXPECTED_SHA" "$ARCHIVE" | sha256sum -c -

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR"
chmod 0755 "$INSTALL_DIR"
chmod 0700 "$CONFIG_DIR" "$DATA_DIR"
tar -xzf "$ARCHIVE" -C "$TMP_DIR"
install -m 0755 "${TMP_DIR}/relaydeck-lite" "${INSTALL_DIR}/relaydeck-lite"

SERVICE_STARTED=0
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  SERVICE_FILE="${TMP_DIR}/relaydeck-lite.service"
  download "${RAW_BASE}/${TAG}/deploy/relaydeck-lite.service" "$SERVICE_FILE"
  install -m 0644 "$SERVICE_FILE" /etc/systemd/system/relaydeck-lite.service
  systemctl daemon-reload
  if [ "$NO_START" -eq 0 ]; then
    systemctl enable --now relaydeck-lite
    SERVICE_STARTED=1
  else
    systemctl enable relaydeck-lite
  fi
elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
  SERVICE_FILE="${TMP_DIR}/relaydeck-lite.openrc"
  download "${RAW_BASE}/${TAG}/deploy/relaydeck-lite.openrc" "$SERVICE_FILE"
  install -m 0755 "$SERVICE_FILE" /etc/init.d/relaydeck-lite
  rc-update add relaydeck-lite default >/dev/null 2>&1 || true
  if [ "$NO_START" -eq 0 ]; then
    rc-service relaydeck-lite start
    SERVICE_STARTED=1
  fi
else
  log "未检测到 systemd/OpenRC，已完成二进制安装。"
fi

log "安装完成：${INSTALL_DIR}/relaydeck-lite"
log "配置目录：${CONFIG_DIR}"
log "控制 socket：${SOCKET_PATH}"

if [ "$NO_START" -eq 1 ]; then
  log "已跳过启动，可手动执行：${INSTALL_DIR}/relaydeck-lite run --config ${CONFIG_DIR}/rules.json --socket ${SOCKET_PATH}"
elif [ "$SERVICE_STARTED" -eq 0 ]; then
  log "请先手动启动守护进程，再运行：${INSTALL_DIR}/relaydeck-lite"
fi

if [ "$NO_MENU" -eq 0 ] && [ -t 0 ] && [ "$SERVICE_STARTED" -eq 1 ]; then
  exec "${INSTALL_DIR}/relaydeck-lite" menu --socket "$SOCKET_PATH"
fi

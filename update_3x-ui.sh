#!/bin/bash

# ============================================================
#  3x-ui 一键更新脚本
#  支持: Debian / Ubuntu / CentOS / RHEL / Rocky / Alma
#  使用: bash update_3x-ui.sh  或  bash update_3x-ui.sh v2.6.0
# ============================================================

set -e

# ---------- 必须是 bash (Ubuntu/Debian 的 sh=dash,不支持 mapfile/数组/[[ ]]) ----------
if [ -z "$BASH_VERSION" ]; then
    echo -e "\033[0;31m错误: 必须用 bash 运行此脚本,不要用 sh\033[0m"
    echo "正确用法:"
    echo "  bash update_3x-ui.sh"
    echo "  bash update_3x-ui.sh v2.6.0"
    exit 1
fi

# ---------- 帮助 (放在最前,免 sudo 也能查) ----------
case "${1:-}" in
    "-h"|"--help"|"help")
        echo "用法: bash $0 [版本号]"
        echo "  无参数         交互选择版本"
        echo "  <版本号>       直接安装指定版本 (例: bash $0 v2.6.0)"
        echo "  -h, --help     显示帮助"
        echo ""
        echo "示例:"
        echo "  bash $0              # 弹出版本菜单"
        echo "  bash $0 v2.6.0       # 静默安装 v2.6.0"
        exit 0 ;;
esac

# ---------- 颜色 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------- 配置 ----------
REPO="MHSanaei/3x-ui"
INSTALL_DIR="/usr/local/x-ui"
SERVICE_NAME="x-ui"
BACKUP_DIR="/var/tmp/x-ui-backup-$(date +%Y%m%d-%H%M%S)"

# ---------- 检查 root ----------
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 请使用 root 用户运行此脚本${NC}"
    exit 1
fi

echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}       3x-ui 一键更新脚本${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""

# ---------- 检查已安装 ----------
if [ ! -f "${INSTALL_DIR}/x-ui" ]; then
    echo -e "${RED}错误: 未检测到 3x-ui 安装 (${INSTALL_DIR}/x-ui)${NC}"
    echo "请先安装 3x-ui: https://github.com/MHSanaei/3x-ui"
    exit 1
fi

# ---------- 当前版本 (多方式兜底检测) ----------
CURRENT_VER=""
if [ -x "${INSTALL_DIR}/x-ui" ]; then
    for cmd in version -v --version; do
        out=$("${INSTALL_DIR}/x-ui" $cmd 2>/dev/null)
        detected=$(echo "$out" | grep -oP 'v?\d+\.\d+(\.\d+)?' | head -1)
        if [ -n "$detected" ]; then
            CURRENT_VER="$detected"
            break
        fi
    done
    # 最后兜底:从二进制 strings 里抓
    if [ -z "$CURRENT_VER" ] && command -v strings >/dev/null 2>&1; then
        CURRENT_VER=$(strings "${INSTALL_DIR}/x-ui" 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1)
    fi
fi
echo -e "${YELLOW}[1/7] 当前版本: ${CURRENT_VER:-未知}${NC}"

# ---------- 架构识别 ----------
ARCH=$(uname -m)
case $ARCH in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l)  ARCH="armv7" ;;
    *)       echo -e "${RED}错误: 不支持的架构 ${ARCH}${NC}"; exit 1 ;;
esac
echo -e "${YELLOW}[2/7] 系统架构: ${ARCH}${NC}"

# ---------- 命令行参数 ----------
CLI_VERSION=""
case "${1:-}" in
    ""|"-i"|"--interactive") ;;
    -*) echo -e "${RED}未知参数: $1 (使用 bash $0 --help 查看用法)${NC}"; exit 1 ;;
    *)  CLI_VERSION="$1" ;;
esac

# ---------- 命令行指定版本:直接校验并确认 ----------
if [ -n "$CLI_VERSION" ]; then
    TARGET_VERSION="$CLI_VERSION"
    echo -e "${YELLOW}[3/7] 命令行指定版本: ${TARGET_VERSION}${NC}"
    TARGET_URL="https://github.com/${REPO}/releases/download/${TARGET_VERSION}/x-ui-linux-${ARCH}.tar.gz"
    if ! curl -fsI "$TARGET_URL" -o /dev/null --max-time 15; then
        echo -e "${RED}版本 ${TARGET_VERSION} 没有 linux-${ARCH} 资源${NC}"
        echo "查看可用版本: bash $0  (不加参数)"
        exit 1
    fi
    if [ "$TARGET_VERSION" != "$CURRENT_VER" ]; then
        read -p "确认从 ${CURRENT_VER:-未知} 更新到 ${TARGET_VERSION}? [y/N]: " CONFIRM
        [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { echo "已取消"; exit 0; }
    fi
    echo ""
fi

# ---------- 交互模式:从 atom feed 拉取版本列表 ----------
if [ -z "$TARGET_VERSION" ]; then
    echo -e "${YELLOW}[3/7] 正在获取版本列表 (atom feed)...${NC}"
    ATOM=$(curl -fsSL --max-time 20 "https://github.com/${REPO}/releases.atom") || {
        echo -e "${RED}错误: 无法获取版本列表 (请检查到 github.com 的网络)${NC}"
        exit 1
    }

    mapfile -t VERSIONS < <(echo "$ATOM" | grep -oP '<title>\K[^<]+' | tail -n +2)
    mapfile -t DATES   < <(echo "$ATOM" | grep -oP '<updated>\K[^<]+' | cut -c1-10)

    if [ ${#VERSIONS[@]} -eq 0 ]; then
        echo -e "${RED}错误: 解析版本列表失败${NC}"
        exit 1
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    echo -e "${CYAN}  可用版本 (最近 ${#VERSIONS[@]} 个,默认最新)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    for i in "${!VERSIONS[@]}"; do
        NUM=$((i+1))
        MARKER=""
        [ "$i" -eq 0 ] && MARKER="${GREEN}★ 最新${NC}"
        [ "${VERSIONS[$i]}" = "$CURRENT_VER" ] && MARKER="$MARKER ${YELLOW}← 当前已装${NC}"
        [[ "${VERSIONS[$i]}" =~ -(rc|beta|alpha|pre|dev) ]] && MARKER="$MARKER ${RED}(预发布)${NC}"
        printf "  %2d) %-15s %s %b\n" "$NUM" "${VERSIONS[$i]}" "${DATES[$i]}" "$MARKER"
    done
    echo "   c) 自定义版本号 (例 v2.6.0)"
    echo "   q) 取消"
    echo -e "${CYAN}───────────────────────────────────────────${NC}"

    read -p "请选择 [1]: " CHOICE
    CHOICE=${CHOICE:-1}

    case "$CHOICE" in
        q|Q) echo "已取消"; exit 0 ;;
        c|C) read -p "请输入版本标签: " TARGET_VERSION
             [ -z "$TARGET_VERSION" ] && { echo -e "${RED}版本号不能为空${NC}"; exit 1; } ;;
        *)   if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#VERSIONS[@]}" ]; then
                 TARGET_VERSION="${VERSIONS[$((CHOICE-1))]}"
             else
                 echo -e "${RED}无效选择: $CHOICE${NC}"; exit 1
             fi
             ;;
    esac

    TARGET_URL="https://github.com/${REPO}/releases/download/${TARGET_VERSION}/x-ui-linux-${ARCH}.tar.gz"
    echo -e "${YELLOW}  验证 ${TARGET_VERSION} 资源...${NC}"
    if ! curl -fsI "$TARGET_URL" -o /dev/null --max-time 15; then
        echo -e "${RED}版本 ${TARGET_VERSION} 没有 linux-${ARCH} 资源,请换个版本${NC}"
        exit 1
    fi
    echo ""

    # ---------- 确认更新 ----------
    if [ "$TARGET_VERSION" = "$CURRENT_VER" ]; then
        read -p "目标与当前一致 (${TARGET_VERSION}),确认重装? [y/N]: " CONFIRM
    else
        read -p "确认从 ${CURRENT_VER:-未知} 更新到 ${TARGET_VERSION}? [y/N]: " CONFIRM
    fi
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "已取消"
        exit 0
    fi
    echo ""
fi

# ---------- 备份 ----------
echo -e "${YELLOW}[4/7] 正在备份...${NC}"
mkdir -p "$BACKUP_DIR"
cp -f ${INSTALL_DIR}/x-ui $BACKUP_DIR/ 2>/dev/null || true
cp -f ${INSTALL_DIR}/x-ui.db $BACKUP_DIR/ 2>/dev/null || true
[ -d ${INSTALL_DIR}/web ] && cp -rf ${INSTALL_DIR}/web $BACKUP_DIR/
[ -d ${INSTALL_DIR}/bin ] && cp -rf ${INSTALL_DIR}/bin $BACKUP_DIR/
echo -e "${GREEN}  备份完成: ${BACKUP_DIR}${NC}"
echo ""

# ---------- 停止服务 ----------
echo -e "${YELLOW}[5/7] 停止 x-ui 服务...${NC}"
systemctl stop ${SERVICE_NAME} 2>/dev/null || true
sleep 1
echo ""

# ---------- 下载 & 安装 (流式解压,避免 /tmp 空间不够) ----------
echo -e "${YELLOW}[6/7] 下载并安装新版本...${NC}"

# tarball 顶层是 x-ui/,--strip-components=1 去掉这层,直接展开到安装目录
if ! curl -fL "$TARGET_URL" | tar -xz --strip-components=1 -C "$INSTALL_DIR"; then
    echo -e "${RED}下载/解压失败,正在回滚...${NC}"
    # 清理可能解压不完整的 web/bin 目录,再从备份恢复
    rm -rf "${INSTALL_DIR}/web" "${INSTALL_DIR}/bin"
    [ -d $BACKUP_DIR/web ] && cp -rf $BACKUP_DIR/web ${INSTALL_DIR}/
    [ -d $BACKUP_DIR/bin ] && cp -rf $BACKUP_DIR/bin ${INSTALL_DIR}/
    cp -f $BACKUP_DIR/x-ui ${INSTALL_DIR}/x-ui
    systemctl start ${SERVICE_NAME}
    exit 1
fi

chmod +x ${INSTALL_DIR}/x-ui
[ -f ${INSTALL_DIR}/x-ui.service ] && cp -f ${INSTALL_DIR}/x-ui.service /etc/systemd/system/${SERVICE_NAME}.service

systemctl daemon-reload
echo ""

# ---------- 启动并验证 ----------
echo -e "${YELLOW}[7/7] 启动并验证...${NC}"
systemctl start ${SERVICE_NAME}
systemctl enable ${SERVICE_NAME} 2>/dev/null || true
sleep 2

if systemctl is-active --quiet ${SERVICE_NAME}; then
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}  ✓ 更新成功!${NC}"
    echo -e "${GREEN}=========================================${NC}"
    systemctl restart ${SERVICE_NAME}
    sleep 1
    echo ""
    echo -e "${CYAN}── 当前版本 ──${NC}"
    echo -e "${GREEN}${TARGET_VERSION}${NC}"
    echo ""
    echo -e "${CYAN}── 服务状态 ──${NC}"
    systemctl status ${SERVICE_NAME} --no-pager 2>/dev/null | head -4 || true
    echo ""
    echo -e "备份位置: ${CYAN}${BACKUP_DIR}${NC}"
    echo -e "回滚命令: ${CYAN}cp ${BACKUP_DIR}/x-ui ${INSTALL_DIR}/x-ui && systemctl restart ${SERVICE_NAME}${NC}"
else
    echo -e "${RED}服务启动失败,正在回滚...${NC}"
    cp -f $BACKUP_DIR/x-ui ${INSTALL_DIR}/x-ui
    systemctl start ${SERVICE_NAME}
    echo -e "${YELLOW}已回滚到旧版本,请查看日志: journalctl -u x-ui -n 50${NC}"
    exit 1
fi

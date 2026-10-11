#!/usr/bin/env bash
# ================================================================
# 双机型同时编译 —— HG5585F-CT + XG-040G-MD
#
#   一次 fork、一次提交，然后触发两个独立的 workflow run。
#   真正的编译都在 GitHub 免费 runner 上跑。
#
# 用法：
#   export GITHUB_TOKEN='ghp_gggbin2026'
#   ./dual-build.sh preheat   # ① 预热工具链（只跑一次，两机型共用）
#   ./dual-build.sh build     # ② 预热跑绿后，同时触发两个机型的固件编译
#
#   MD_PARAMS=tf ./dual-build.sh build   # MD 用 TF 版本而不是 MD-UBI
#
# 为什么是两个 run 而不是 profile=all：
#   profile=all 会回退到 configs/an7581.config（SoC 通用配置），
#   我们定制的打印服务器 / 测速 / rtp2httpd 全在里面丢了。
#   而且两个机型 NPU 参数不同（clanker+MT7916 vs stock），无法合并。
# ================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM_OWNER="qwe-qaq"
UPSTREAM_REPO="Actions-OpenWrt-AN758X"
WORKFLOW_FILE="build-ponwrt.yml"
BRANCH="main"

MD_PROFILE="${MD_PARAMS:-nokia_xg-040g-md-ubi}"   # tf 可改成 nokia_xg-040g-tf-ubi

# 三个 config 一次全交；diy-part1.sh 与首启脚本两个机型共用一份
declare -a FILES=(
  "configs/fiberhome_hg5585f-ct.config"
  "configs/${MD_PROFILE}.config"
  "diy-part1.sh"
  "files/etc/uci-defaults/97-print-speedtest"
)

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
info() { printf '%s▶ %s%s\n' "$GRN" "$*" "$RST"; }
warn() { printf '%s! %s%s\n' "$YEL" "$*" "$RST"; }
die()  { printf '%s✗ %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }

command -v curl >/dev/null || die "需要 curl"
command -v jq   >/dev/null || die "需要 jq"
command -v git  >/dev/null || die "需要 git"
[ -n "${GITHUB_TOKEN:-}" ] || die "请先 export GITHUB_TOKEN='ghp_xxx'"

for f in "${FILES[@]}"; do
  [ -f "$SCRIPT_DIR/$f" ] || die "缺少文件: $f"
done

api() {
  local m="$1" p="$2" d="${3:-}"
  local args=(-sS -X "$m" \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28")
  [ -n "$d" ] && args+=(-H "Content-Type: application/json" -d "$d")
  curl "${args[@]}" "https://api.github.com${p}"
}

info "校验 Token ..."
ME="$(api GET /user | jq -r '.login // empty')"
[ -n "$ME" ] || die "Token 无效或权限不足"
info "账号: ${ME}"

# ---------------- Fork（只做一次）----------------
FORK_FULL="${ME}/${UPSTREAM_REPO}"
if api GET "/repos/${FORK_FULL}" | jq -e '.full_name' >/dev/null 2>&1; then
  info "已存在 fork: ${FORK_FULL}"
else
  info "fork ${UPSTREAM_OWNER}/${UPSTREAM_REPO} ..."
  api POST "/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/forks" \
      "{\"name\":\"${UPSTREAM_REPO}\",\"default_branch_only\":true}" >/dev/null
  printf '   等待就绪'
  for i in $(seq 1 60); do
    api GET "/repos/${FORK_FULL}" | jq -e '.full_name' >/dev/null 2>&1 && { echo " OK"; break; }
    [ "$i" -eq 60 ] && { echo; die "fork 超时"; }
    printf '.'; sleep 5
  done
fi

info "启用 Actions ..."
api PUT "/repos/${FORK_FULL}/actions/permissions" \
    '{"enabled":true,"allowed_actions":"all"}' >/dev/null
sleep 3

# ---------------- 提交（只做一次）----------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

info "克隆 fork ..."
git clone --depth 1 -q \
  "https://x-access-token:${GITHUB_TOKEN}@github.com/${FORK_FULL}.git" \
  "$WORK/repo" 2>/dev/null || die "克隆失败"
cd "$WORK/repo"
git config user.name  "auto-build"
git config user.email "auto-build@users.noreply.github.com"

info "写入定制文件 ..."
for f in "${FILES[@]}"; do
  mkdir -p "$(dirname "$f")"
  cp "$SCRIPT_DIR/$f" "$f"
done
chmod +x diy-part1.sh files/etc/uci-defaults/97-print-speedtest

if [ -z "$(git status --porcelain)" ]; then
  warn "文件无变化，跳过提交"
else
  git add -A
  git commit -q -m "feat: add print server + netspeedtest + rtp2httpd for hg5585f-ct & ${MD_PROFILE}"
  git push -q origin "HEAD:${BRANCH}"
  info "已提交并推送"
fi

# ---------------- 触发 ----------------
dispatch() {  # dispatch <profile> <scope> <npu_fw> <npu_wifi> <npu_wlan_mem>
  local profile="$1" scope="$2" npu_fw="$3" npu_wifi="$4" wlan_mem="$5"
  local payload code
  payload=$(jq -n \
    --arg ref "$BRANCH" --arg p "$profile" --arg s "$scope" \
    --arg fw "$npu_fw" --arg w "$npu_wifi" --arg m "$wlan_mem" '{
    ref: $ref,
    inputs: {
      source: "fork", branch: "npu", soc: "an7581",
      profile: $p, scope: $s,
      npu_fw: $fw, npu_wifi: $w, npu_wlan_mem: $m
    }
  }')
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" -d "$payload" \
    "https://api.github.com/repos/${FORK_FULL}/actions/workflows/${WORKFLOW_FILE}/dispatches")
  [ "$code" = "204" ] || die "触发 ${profile}/${scope} 失败（HTTP ${code}）"
  info "已触发: ${profile} (scope=${scope}, npu_fw=${npu_fw}, wifi=${npu_wifi}, wlan_mem=${wlan_mem})"
}

MODE="${1:-}"

case "$MODE" in
  preheat)
    # 工具链缓存 key = ponwrt-toolchain-airoha-an7581-<hash>
    # 两个机型 TARGET/SUBTARGET 都是 airoha/an7581，源码同一份 → key 相同
    # 所以只预热一次，两个机型都能命中
    info "第 ① 步：预热工具链缓存（两机型共用，只跑这一次）"
    dispatch "fiberhome_hg5585f-ct" "toolchain-only" "clanker" "MT7916" "true"
    cat <<EOF

  ${DIM}这一步不出固件，约 30~60 分钟。
  去 https://github.com/${FORK_FULL}/actions 看到它跑绿（✅）后执行：${RST}

      GITHUB_TOKEN='\${GITHUB_TOKEN}' $0 build
EOF
    ;;

  build)
    info "第 ② 步：同时触发两个机型的固件编译"

    # HG5585F-CT：有 WiFi(MT7916D) → clanker + MT7916 + 补 WiFi 保留内存
    dispatch "fiberhome_hg5585f-ct" "firmware" "clanker" "MT7916" "true"

    # XG-040G-MD：无 WiFi → stock 固件 + 不补 WiFi 保留内存
    dispatch "${MD_PROFILE}"       "firmware" "stock"   "MT7916" "false"

    cat <<EOF

${GRN}================ 两个编译任务已同时提交 ================${RST}

  ${DIM}两者并发跑，互不干扰（Release tag 不同、机型校验独立）。
  工具链缓存 key 相同，所以刚才那次预热两个都能命中。${RST}

  进度：  https://github.com/${FORK_FULL}/actions

  产物1： Releases → ponwrt-an7581-fiberhome_hg5585f-ct-npu
          ponwrt-airoha-an7581-fiberhome_hg5585f-ct-squashfs-sysupgrade.itb

  产物2： Releases → ponwrt-an7581-${MD_PROFILE}-npu
          ponwrt-airoha-an7581-${MD_PROFILE}-squashfs-sysupgrade.itb

${YEL}配额提醒：${RST}免费账号每月 2000 分钟。两个固件加起来约 2~4 小时，
          注意剩余额度（Settings → Billing → Usage）。

${YEL}小概率：${RST}两个 run 同时结束时，保存工具链缓存可能撞同一个 key，
          其中一个会跳过保存（有 continue-on-error，不影响固件产出）。

${YEL}安全：${RST}用完去 https://github.com/settings/tokens 删掉 Token
EOF
    ;;

  *)
    echo "用法: $0 {preheat|build}"
    echo "  preheat  预热工具链（只跑一次，两机型共用）"
    echo "  build    预热跑绿后，同时触发两个机型的固件编译"
    exit 1
    ;;
esac

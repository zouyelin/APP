#!/bin/bash
# ============================================================
#  一键同步上游仓库（只同步文件，不编译、不推送）
#
#  上游：https://github.com/pxx917144686/APP
#  本地：https://github.com/zouyelin/APP
#
#  同步后自动重新打上两处自定义改动：
#    1. APP/Views/TabView/TabView.swift:73
#       selectedTab: TabEnum = .settings  →  .search
#    2. APP/Views/Download/DownloadView.swift:1031
#       https://github.com/pxx917144686   →  https://github.com/zouyelin/APP
#  .github/workflows/ios.yml 保留你自己的（不被上游覆盖）
#
#  用法：把这个文件放到 zouyelin/APP 仓库根目录，双击运行。
# ============================================================
set -u

cd "$(dirname "$0")" || exit 1

OWNER_UP="pxx917144686"
REPO_UP="APP"
BRANCH_UP="main"
WORKDIR="$(pwd)"
STAMP=$(date +%Y%m%d_%H%M%S)
BACKUP="../APP_sync_backup_$STAMP"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
say()  { printf "%s==>%s %s\n" "$C_B" "$C_0" "$1"; }
ok()   { printf "%s ✓ %s %s\n" "$C_G" "$C_0" "$1"; }
warn() { printf "%s ! %s %s\n" "$C_Y" "$C_0" "$1"; }
die()  { printf "%s ✗ %s %s\n" "$C_R" "$C_0" "$1"; echo; read -n 1 -s -r -p "按任意键退出..."; exit 1; }

echo "=============================================="
echo "   同步上游 APP 仓库（仅文件）"
echo "=============================================="
echo

# ---------- 1. 前置检查 ----------
command -v git >/dev/null 2>&1 || die "没找到 git，请先执行 xcode-select --install"
[ -d .git ] || die "当前目录不是 git 仓库：$WORKDIR
请把这个脚本放到 zouyelin/APP 的仓库根目录再双击。"

say "本地仓库: $WORKDIR"
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
echo "    当前分支: $BRANCH"
[ -n "$(git status --porcelain)" ] && warn "有未提交的改动，会先完整备份"

# ---------- 2. 备份 ----------
say "备份到 $BACKUP"
mkdir -p "$BACKUP" || die "备份目录创建失败"
for item in APP APP.xcodeproj Makefile README.md X .github; do
  [ -e "$item" ] && cp -R "$item" "$BACKUP/" 2>/dev/null
done
ok "备份完成"

# ---------- 3. 拉上游（tarball 优先，git clone 兜底）----------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
UPSRC=""

fetch_tarball() {
  local url="$1" out="$TMP/up.tgz" i
  for i in 1 2 3; do
    echo "    尝试 $i/3: ${url:0:72}..."
    if curl -fSL --connect-timeout 20 --max-time 300 --retry 2 --retry-delay 2 \
            -C - "$url" -o "$out" 2>/dev/null; then
      if tar -tzf "$out" >/dev/null 2>&1; then
        mkdir -p "$TMP/up" && tar -xzf "$out" -C "$TMP/up" --strip-components=1 2>/dev/null \
          && [ -f "$TMP/up/Makefile" ] && return 0
      fi
    fi
    rm -f "$out"; sleep 2
  done
  return 1
}

say "下载上游 $OWNER_UP/$REPO_UP ($BRANCH_UP)"
if fetch_tarball "https://codeload.github.com/$OWNER_UP/$REPO_UP/tar.gz/refs/heads/$BRANCH_UP" \
   || fetch_tarball "https://api.github.com/repos/$OWNER_UP/$REPO_UP/tarball/$BRANCH_UP"; then
  UPSRC="$TMP/up"
  ok "下载完成"
else
  warn "tarball 下载失败，改用 git clone"
  for i in 1 2; do
    git clone --depth 1 "https://github.com/$OWNER_UP/$REPO_UP.git" "$TMP/up" 2>/dev/null && break
    rm -rf "$TMP/up"; sleep 2
  done
  [ -f "$TMP/up/Makefile" ] && UPSRC="$TMP/up" || die "拉取上游失败（网络问题，可稍后重试或挂代理）"
  ok "clone 完成"
fi

# 版本信息（tarball 没有 .git，从 README 或文件推断）
UP_VER=$(grep -m1 -oE '([0-9]+\.[0-9]+\.[0-9]+)' "$UPSRC/README.md" 2>/dev/null | head -1)
[ -n "$UP_VER" ] && echo "    上游版本: $UP_VER"

# ---------- 4. 同步文件 ----------
say "同步文件（跳过 .git 与 .github）"
CHANGED=0; NEW=0; DEL=0
cd "$UPSRC" || die "进入上游目录失败"

# 用 find 而不是 git ls-files（tarball 没有 .git）
while IFS= read -r f; do
  f="${f#./}"
  case "$f" in
    .git/*|.github/*|.DS_Store|*/.DS_Store) continue ;;
  esac
  [ -f "$f" ] || continue
  mkdir -p "$WORKDIR/$(dirname "$f")" 2>/dev/null
  if [ ! -e "$WORKDIR/$f" ]; then
    cp "$f" "$WORKDIR/$f"; echo "    新增: $f"; NEW=$((NEW+1))
  elif ! cmp -s "$f" "$WORKDIR/$f"; then
    cp "$f" "$WORKDIR/$f"; echo "    更新: $f"; CHANGED=$((CHANGED+1))
  fi
done < <(find . -type f ! -path "./.git/*" ! -path "./.github/*")

cd "$WORKDIR" || die "回到工作目录失败"

# 删除上游已移除的文件（只看 git 跟踪的，且跳过保留项）
while IFS= read -r f; do
  case "$f" in
    .git/*|.github/*|.DS_Store|*/.DS_Store) continue ;;
  esac
  if [ ! -e "$UPSRC/$f" ] && [ -e "$WORKDIR/$f" ]; then
    rm -f "$WORKDIR/$f"; echo "    删除: $f"; DEL=$((DEL+1))
  fi
done < <(git -C "$WORKDIR" ls-files)

ok "新增 $NEW / 更新 $CHANGED / 删除 $DEL"

# ---------- 5. 重新应用自定义改动 ----------
say "重新应用自定义改动"

# 5.1 底栏对调（搜索/设置互换位置）+ 默认进搜索页
TV="APP/Views/TabView/TabView.swift"
if [ -f "$TV" ]; then
  python3 - "$TV" <<'PYEOF'
import re, sys, pathlib

path = pathlib.Path(sys.argv[1])
s = path.read_text(encoding="utf-8")
orig = s
ORDER = ["search", "downloads", "purchased", "settings"]


def fail(msg):
    print("    ! " + msg)
    print("    ! 底栏对调未应用，文件保持上游原样")
    sys.exit(0)          # 不视为失败，仓同步本身是成功的


m = re.search(r"(enum TabEnum[^{]*\{\n)((?:    case \w+\n)+)", s)
if not m:
    fail("找不到 enum TabEnum 的 case 列表")
head, cases = m.group(1), m.group(2)
found = re.findall(r"    case (\w+)\n", cases)
if any(x not in found for x in ORDER):
    fail("enum 缺 case：" + ", ".join(x for x in ORDER if x not in found))
new_cases = "".join("    case %s\n" % x for x in ORDER)
s = s[:m.start(2)] + new_cases + s[m.end(2):]

def reorder(text, start_marker, end_marker, first_indent, tag_indent):
    a = text.index(start_marker)
    b = text.index(end_marker, a)
    seg = text[a:b]
    raw = {}
    for n in ORDER:
        pat = re.compile(
            r"(" + " " * first_indent + r"TabEnum\.view\(for: \." + n +
            r"[^\n]*\n(?:(?!" + " " * first_indent + r"TabEnum\.view).)*?" +
            " " * tag_indent + r"\.tag\(TabEnum\." + n + r"\)\n)", re.S)
        mm = pat.search(seg)
        if not mm:
            fail("在 %s 区块里找不到 %s" % (start_marker.strip(), n))
        raw[n] = mm.group(1)
    for n in ORDER:
        seg = seg.replace(raw[n], "", 1)
    am = re.search(r"^[ \t]*TabView\(selection: \$selectedTab\) \{\n", seg, re.M)
    if not am:
        fail("在 %s 区块里找不到 TabView(selection:)" % start_marker.strip())
    seg = seg.replace(am.group(0), am.group(0) + "".join(raw[n] for n in ORDER), 1)
    return text[:a] + seg + text[b:]

try:
    s = reorder(s, "private var standardTabView", "private var floatingCardTabView", 12, 16)
    s = reorder(s, "private var floatingCardTabView", "private var floatingTabBarContent", 20, 24)
except ValueError:
    fail("找不到 standardTabView / floatingCardTabView 区块")

bar_start = s.find("private var floatingTabBarContent")
if bar_start < 0:
    fail("找不到 floatingTabBarContent")
bar = s[bar_start:]
for old, new in [
    ("ForEach([TabEnum.settings, .downloads, .purchased], id: \\.self)",
     "ForEach([TabEnum.search, .downloads, .purchased], id: \\.self)"),
    ("selectedTab = .search\n                }\n                let impactMed",
     "selectedTab = .settings\n                }\n                let impactMed"),
    ("if selectedTab == .search {\n                        Circle()\n                            .fill(themeManager.accentColor)",
     "if selectedTab == .settings {\n                        Circle()\n                            .fill(themeManager.accentColor)"),
    ("Text(TabEnum.search.emojiIcon)\n                }\n                .frame(width: tabHeight, height: tabHeight)",
     "Text(TabEnum.settings.emojiIcon)\n                }\n                .frame(width: tabHeight, height: tabHeight)"),
    (".stroke(Color.white.opacity(selectedTab == .search ? 0 : 0.15), lineWidth: 0.5)",
     ".stroke(Color.white.opacity(selectedTab == .settings ? 0 : 0.15), lineWidth: 0.5)"),
]:
    if old in bar:
        bar = bar.replace(old, new, 1)
s = s[:bar_start] + bar

s = s.replace("@State private var selectedTab: TabEnum = .settings",
              "@State private var selectedTab: TabEnum = .search", 1)

def balance(t):
    t2 = re.sub(r'"(?:[^"\\]|\\.)*"', '""', t)
    t2 = re.sub(r"//[^\n]*", "", t2)
    return {c: (t2.count(c), t2.count({"{" : "}", "(": ")", "[": "]"}[c])) for c in "{(["}

bad = [k for k, (o, c) in balance(s).items() if o != c]
if bad:
    fail("改动后括号不平衡（%s），已放弃写入" % ", ".join(bad))

if s == orig:
    print("    ✓ 底栏顺序（已是 搜索/下载/已购/设置）")
else:
    path.write_text(s, encoding="utf-8")
    print("    ✓ 底栏已对调 → 搜索 / 下载 / 已购 / 设置（默认进搜索页）")
PYEOF
else
  warn "找不到 $TV，跳过底栏对调"
fi

# 5.2 下载页「查看源代码」指向你的仓库
DV="APP/Views/Download/DownloadView.swift"
if [ -f "$DV" ]; then
  if grep -q "https://github.com/pxx917144686" "$DV"; then
    sed -i '' 's|https://github.com/pxx917144686|https://github.com/zouyelin/APP|g' "$DV"
    ok "源码链接 → github.com/zouyelin/APP ✓ ($DV)"
  elif grep -q "https://github.com/zouyelin/APP" "$DV"; then
    ok "源码链接（已是）"
  else
    warn "没找到源码链接那一行，请手动检查 $DV"
    grep -n "github.com" "$DV" | head -5
  fi
else
  warn "找不到 $DV"
fi

[ -f ".github/workflows/ios.yml" ] && ok "已保留你自己的 .github/workflows/ios.yml（跳过上游）"

# ---------- 6. 汇总 ----------
echo
echo "----------------------------------------------"
say "改动汇总"
git -C "$WORKDIR" status --porcelain | head -40
CNT=$(git -C "$WORKDIR" status --porcelain | wc -l | tr -d ' ')
echo
if [ "$CNT" -gt 0 ]; then
  ok "$CNT 个文件有变动"
  echo
  echo "确认无误后手动推送："
  echo "    cd \"$WORKDIR\""
  echo "    git add -A && git commit -m \"sync upstream ${UP_VER:-latest}\" && git push"
else
  ok "已是最新，没有变动"
fi
echo
echo "备份位置: $BACKUP"
echo
read -n 1 -s -r -p "按任意键关闭..."

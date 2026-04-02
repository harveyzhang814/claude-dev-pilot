#!/bin/sh
# install-git-hooks.sh
# 一键安装分支保护 hooks。复制本文件到任意 git 项目根目录，运行即可。
#
# 规则（可在下方 HOOK_CONTENT 中修改 case 分支适配不同项目）：
#   main    — 禁止直接提交；只接受来自 staging 或 release/* 的合并
#   staging — 禁止直接提交；只接受来自 feature/*, fix/*, chore/*, doc/* 的合并

set -e

REPO_ROOT=$(git rev-parse --show-toplevel)
HOOKS_DIR="$REPO_ROOT/.githooks"
mkdir -p "$HOOKS_DIR"

cat > "$HOOKS_DIR/pre-commit" << 'HOOK_CONTENT'
#!/bin/sh
BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null)
[ -z "$BRANCH" ] && exit 0

IS_MERGE=0
[ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ] && IS_MERGE=1

merge_source_branch() {
    local msg_file
    msg_file="$(git rev-parse --git-dir)/MERGE_MSG"
    [ -f "$msg_file" ] || { echo ""; return; }
    head -1 "$msg_file" | sed "s/Merge branch '//;s/'.*//"
}

if [ "$BRANCH" = "main" ]; then
    if [ "$IS_MERGE" -eq 0 ]; then
        echo "❌ 禁止直接在 main 上提交。请在 staging 或 release/* 分支开发后合并。"
        exit 1
    fi
    SRC=$(merge_source_branch)
    case "$SRC" in
        staging|release/*) exit 0 ;;
        *) echo "❌ main 只接受来自 staging 或 release/* 的合并，当前来源：'${SRC:-unknown}'"; exit 1 ;;
    esac
fi

if [ "$BRANCH" = "staging" ]; then
    if [ "$IS_MERGE" -eq 0 ]; then
        echo "❌ 禁止直接在 staging 上提交。请在 feature/*, fix/*, chore/*, doc/* 分支开发后合并。"
        exit 1
    fi
    SRC=$(merge_source_branch)
    case "$SRC" in
        feature/*|fix/*|chore/*|doc/*) exit 0 ;;
        *) echo "❌ staging 只接受来自 feature/*, fix/*, chore/*, doc/* 的合并，当前来源：'${SRC:-unknown}'"; exit 1 ;;
    esac
fi

exit 0
HOOK_CONTENT

chmod +x "$HOOKS_DIR/pre-commit"
git config core.hooksPath .githooks

echo "✅ Git hooks 已安装 (core.hooksPath = .githooks)"
echo "   受保护分支: main, staging"

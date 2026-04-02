#!/bin/sh
# install-git-hooks.sh
# 一键安装分支保护 hooks。复制本文件到任意 git 项目根目录，运行即可。
#
# 规则（可在下方 heredoc 中修改 case 分支适配不同项目）：
#   pre-commit — main/staging 禁止直提；合并来源须符合命名约定
#   pre-push — 禁止通过 push 删除远程 refs/heads/main、refs/heads/staging
#   merge.ff — 设为 false，禁止默认 fast-forward 合并（无合并提交时 pre-commit 也无法校验来源）
#   说明：本地 git branch -D main 无标准 hook；单次合并仍可用 git merge --ff-only 显式覆盖配置。

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

cat > "$HOOKS_DIR/pre-push" << 'PRE_PUSH_CONTENT'
#!/bin/sh
# $1 = remote name, $2 = remote URL（未使用亦可）
ZERO_SHA=0000000000000000000000000000000000000000

while read -r local_ref local_sha remote_ref remote_sha
do
    [ "$local_sha" = "$ZERO_SHA" ] || continue
    [ -n "$remote_ref" ] || continue
    case "$remote_ref" in
        refs/heads/main|refs/heads/staging)
            echo "❌ 禁止删除受保护分支: ${remote_ref#refs/heads/}"
            echo "   （通过 push 删除远程分支已被拦截；若需调整策略请改 .githooks/pre-push）"
            exit 1
            ;;
    esac
done

exit 0
PRE_PUSH_CONTENT

chmod +x "$HOOKS_DIR/pre-commit" "$HOOKS_DIR/pre-push"
git config core.hooksPath .githooks
git config merge.ff false

echo "✅ Git hooks 已安装 (core.hooksPath = .githooks)"
echo "   pre-commit: main/staging 提交与合并来源"
echo "   pre-push:   禁止删除远程 main、staging"
echo "   merge.ff:   false（禁止默认 fast-forward，合并将产生 merge commit）"

#!/bin/sh
# 观盘 Next 一键更新（在 NAS 上执行）
#
# 用法：把更新包/部署包解压到**任意**目录，然后
#         sh update.sh
#
# 之前为什么总要"全量部署"：更新包里的路径是 server/xxx，必须解到
# 「包含 server/ 的那一层」才对，层级一错容器里就还是旧代码，而 old 行为是静默的。
# 这个脚本自己找出容器对应的 compose 目录再覆盖，所以解压到哪儿都行，不用记路径。
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
VERSION=$(cat "$HERE/server/VERSION" 2>/dev/null | tr -d '\r\n' || true)
if [ -z "$VERSION" ]; then
  # 部署包带顶层目录 guanpan-next/
  if [ -f "$HERE/guanpan-next/server/VERSION" ]; then
    HERE="$HERE/guanpan-next"; VERSION=$(cat "$HERE/server/VERSION" | tr -d '\r\n' || true)
  fi
fi
[ -n "$VERSION" ] || { echo "✗ 找不到 server/VERSION：请在解压后的目录里执行本脚本"; exit 1; }
echo "本包版本：$VERSION"

# 1) 找到正在跑的容器
CONTAINER=$(docker ps --format '{{.Names}}' | grep -i guanpan | head -1 || true)
[ -n "$CONTAINER" ] || { echo "✗ 没找到运行中的 guanpan 容器（先确认容器是启动状态）"; exit 1; }
echo "容器：$CONTAINER"

# 2) compose 的工作目录：compose 就是从这里解析 ./server 的，
#    所以把代码覆盖到 <工作目录>/server 才是容器真正读得到的地方。
WORKDIR=$(docker inspect "$CONTAINER" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null | tr -d '\r' || true)
PROJECT=$(docker inspect "$CONTAINER" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null | tr -d '\r' || true)
[ -n "$WORKDIR" ] || WORKDIR=/opt/stacks/guanpan-next
[ -n "$PROJECT" ] || PROJECT=guanpan-next
echo "部署目录：$WORKDIR（项目 $PROJECT）"

# 3) 覆盖代码
mkdir -p "$WORKDIR/server"
cp -Rf "$HERE/server/." "$WORKDIR/server/"
echo "已覆盖 -> $WORKDIR/server/VERSION = $(cat "$WORKDIR/server/VERSION" 2>/dev/null || echo 未知)"

# 4) 重建容器。不重建镜像：start.sh 会比对两边 VERSION 选新的那份，宿主是新包就够了。
cd "$WORKDIR"
docker compose -p "$PROJECT" up -d --force-recreate
sleep 15

# 5) 自检：codeVersion 必须变成包里的版本
PORT=$(grep -oE '^\s*-\s*"[0-9]+:8786"' compose.yml 2>/dev/null | grep -oE '[0-9]+:' | tr -d ':' | head -1 || true)
[ -n "$PORT" ] || PORT=30001
HEALTH=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/health" 2>/dev/null || true)
echo "--- /health ---"
echo "$HEALTH" | head -c 500; echo
if echo "$HEALTH" | grep -q "\"codeVersion\":\"$VERSION\""; then
  echo "✅ 已生效：$VERSION"
else
  echo "⚠️ 版本号没变（挂载仍未生效），退回重建镜像再试一次"
  docker compose -p "$PROJECT" up -d --build --force-recreate
  sleep 20
  curl -s --max-time 5 "http://127.0.0.1:$PORT/health" 2>/dev/null | head -c 500; echo
  echo "若这次显示 \"codeVersion\":\"$VERSION\" 即为成功。"
fi

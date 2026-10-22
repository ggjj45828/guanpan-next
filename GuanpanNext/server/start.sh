#!/bin/sh
# 启动前把宿主机代码同步进来；没有宿主机代码就用镜像里的版本。
#
# 为什么不是直接把宿主机目录挂到 /app：
# 上一版 compose 写的是 `./server:/app:ro`。当 ./server 在 NAS 上解析不到时
# （目录名不对、更新包解到了子文件夹、面板把 compose 拷到别处执行……），
# Docker 会**自动创建一个空目录**挂上去，把镜像里原本能跑的 /app 整个盖住，
# 结果就是 `python: can't open file '/app/app.py': [Errno 2]`，服务直接起不来。
# 现在改成挂到 /opt/guanpan-src，再在启动时拷贝：挂载源缺失只会退化成「用镜像里的旧代码」，
# 而不是把服务弄死。
set -e
SRC="${GUANPAN_SRC:-/opt/guanpan-src}"
APP="${GUANPAN_APP:-/app}"

if [ -f "$SRC/app.py" ]; then
  for f in "$SRC"/*.py "$SRC"/VERSION; do
    [ -f "$f" ] && cp -f "$f" "$APP"/ 2>/dev/null || true
  done
  if [ -d "$SRC/web" ]; then
    mkdir -p "$APP/web"
    cp -Rf "$SRC/web/." "$APP/web/" 2>/dev/null || true
  fi
  # 留个标记给 /health 的 codeSource：告诉外面这次跑的是宿主机同步进来的代码。
  printf 'host %s\n' "$SRC" > "$APP/.code-source" 2>/dev/null || true
  echo "[start] 已同步宿主机代码 -> 版本 $(cat "$APP/VERSION" 2>/dev/null || echo 未知)"
else
  # 挂载源缺失时**不要**把服务弄死，退化成镜像内置版本；但必须留痕，
  # 否则「部署没生效」从外面完全看不出来（只会看到功能没变、模型名还是旧的）。
  printf 'image (未检测到 %s/app.py，用的镜像内置旧代码)\n' "$SRC" > "$APP/.code-source" 2>/dev/null || true
  echo "[start] 未检测到宿主机代码（$SRC/app.py），使用镜像内置版本 $(cat "$APP/VERSION" 2>/dev/null || echo 未知)"
fi

exec python app.py

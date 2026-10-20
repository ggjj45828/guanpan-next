FROM python:3.12-slim
WORKDIR /app
# 用通配符而不是逐个文件名：worker 依赖 simulations/backtest，
# 逐个列举时漏一个就是启动即崩（ModuleNotFoundError）。
COPY *.py ./
COPY web ./web
# 构建期做一次导入自检，漏文件会在 build 阶段就失败，而不是等你部署完看日志。
RUN python -c "import app; print('imports ok')"
RUN useradd --uid 10001 --create-home guanpan && mkdir /data && chown guanpan:guanpan /data
USER guanpan
EXPOSE 8786
CMD ["python", "app.py"]

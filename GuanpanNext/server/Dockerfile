FROM python:3.12-slim
WORKDIR /app
COPY domain.py market.py workers.py ai.py app.py ./
COPY web ./web
RUN useradd --uid 10001 --create-home guanpan && mkdir /data && chown guanpan:guanpan /data
USER guanpan
EXPOSE 8786
CMD ["python", "app.py"]

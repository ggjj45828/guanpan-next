FROM python:3.12-slim
WORKDIR /app
COPY domain.py market.py app.py ./
RUN useradd --uid 10001 --create-home guanpan && mkdir /data && chown guanpan:guanpan /data
USER guanpan
EXPOSE 8790
CMD ["python", "app.py"]

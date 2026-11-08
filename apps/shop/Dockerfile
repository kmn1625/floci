# syntax=docker/dockerfile:1
# The same app, ready for the cloud: no local disk needed, config from the environment, non-root.
FROM python:3.14.10-slim@sha256:af8a5aa14780025dbfbcfbc81bd8a91ebd87711dd5b0f48ed71090949dd7cb1d
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && pip uninstall -y pip
COPY app.py catalog.py files.py gunicorn.conf.py .
# Shared metrics for the gunicorn workers, on /dev/shm like the rest: the root filesystem is read-only.
ENV PROMETHEUS_MULTIPROC_DIR=/dev/shm/metrics
USER 10001:10001
EXPOSE 8000
# exec-form probe with its own timeout: see runbooks/container-frozen.md in devops-project.
HEALTHCHECK --interval=30s --timeout=4s --retries=3 CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3).status==200 else 1)"]
# Both paths are on /dev/shm: gunicorn's defaults fail on a read-only root filesystem.
ENTRYPOINT ["python", "-m", "gunicorn", "-w", "2", "-b", "0.0.0.0:8000", "--worker-tmp-dir", "/dev/shm", "--control-socket", "/dev/shm/gunicorn.ctl", "app:app"]

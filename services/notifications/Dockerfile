# Build context: the repository root.
FROM python:3.12-slim
WORKDIR /app
COPY services/notifications/pyproject.toml ./
COPY services/notifications/notifications ./notifications
RUN pip install --no-cache-dir .
EXPOSE 8082
CMD ["python", "-m", "notifications"]

FROM python:3.12-slim

ARG APP_VERSION=unknown
ARG GIT_COMMIT=unknown
ENV APP_VERSION=$APP_VERSION
ENV GIT_COMMIT=$GIT_COMMIT


ENV APP_ENV=dev
ENV FAULT_MODE=false

ENV PYTHONDONTWRITEBYTECODE=1

WORKDIR /app


COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .


RUN useradd --create-home --shell /bin/bash appuser \
    && chown -R appuser:appuser /app
USER appuser

EXPOSE 8080

CMD ["gunicorn", "--workers", "1", "--bind", "0.0.0.0:8080", "app:app"]
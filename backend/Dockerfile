FROM python:3.13-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8000

WORKDIR /app

# Install dependencies first so they cache across code changes.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

EXPOSE 8000

# Single worker; scale with Cloud Run instances rather than in-process workers.
# `application` mounts the API under /api (see app/main.py).
CMD ["sh", "-c", "uvicorn app.main:application --host 0.0.0.0 --port ${PORT}"]

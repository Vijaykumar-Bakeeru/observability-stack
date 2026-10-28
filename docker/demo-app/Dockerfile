FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 8000

# opentelemetry-instrument auto-wraps the process so auto-instrumentation
# (Flask, logging, requests, etc.) is picked up without code changes beyond
# what's already in app.py for the manual span/metric.
CMD ["opentelemetry-instrument", "--service_name", "demo-app", \
     "python", "app.py"]

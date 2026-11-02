FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
WORKDIR /app
RUN pip install --no-cache-dir numpy requests yfinance
COPY app.py /app/app.py
CMD ["python", "-u", "/app/app.py"]

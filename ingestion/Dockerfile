FROM python:3.11-slim

WORKDIR /app

COPY ingestion/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY ingestion/fetch_movies.py ./ingestion/fetch_movies.py
COPY monitoring/ ./monitoring/

ENV PYTHONUNBUFFERED=1

CMD ["python", "ingestion/fetch_movies.py"]
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY fetch_movies.py .

ENV PYTHONUNBUFFERED=1

CMD ["python", "fetch_movies.py"]
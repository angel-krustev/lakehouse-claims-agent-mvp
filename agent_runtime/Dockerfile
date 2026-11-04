# AgentCore Runtime requires an ARM64 image listening on 0.0.0.0:8080.
#   docker buildx build --platform linux/arm64 -t <ecr-uri>:<tag> --push agent_runtime
FROM --platform=linux/arm64 public.ecr.aws/docker/library/python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .

RUN useradd -m -u 1000 agent
USER agent

EXPOSE 8080
CMD ["python", "main.py"]

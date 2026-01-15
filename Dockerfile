FROM ghcr.io/astral-sh/uv:python3.10-bookworm-slim
WORKDIR /app

# All environment variables in one layer
ENV UV_SYSTEM_PYTHON=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_NO_PROGRESS=1 \
    PYTHONUNBUFFERED=1 \
    DOCKER_CONTAINER=1

# OTEL/X-Ray configuration will be injected via runtime environment variables
# See terraform/bedrock_agentcore.tf for OTEL_TRACES_EXPORTER configuration



COPY pyproject.toml pyproject.toml
# Install from requirements file (includes aws-opentelemetry-distro and boto3)
RUN uv pip install -r pyproject.toml


# Signal that this is running in Docker for host binding logic
ENV DOCKER_CONTAINER=1

# Create non-root user
RUN useradd -m -u 1000 bedrock_agentcore
USER bedrock_agentcore

EXPOSE 9000
EXPOSE 8000
EXPOSE 8080

# Copy entire project (respecting .dockerignore)
COPY . .

# Use the full module path

CMD ["opentelemetry-instrument", "python", "-m", "src.main"]

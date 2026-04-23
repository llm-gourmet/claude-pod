FROM python:3.11-slim-bookworm

# Install iptables for Phase 2 (not used in Phase 1 stub)
RUN apt-get update && \
    apt-get install -y --no-install-recommends iptables iproute2 dnsutils && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mkdir -p /data && mkdir -p /var/log/claude-pod

COPY validator.py .

EXPOSE 8088

CMD ["python3", "validator.py"]

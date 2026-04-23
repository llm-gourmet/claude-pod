FROM node:22-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends openssl && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/log/claude-pod

WORKDIR /app

# Generate self-signed cert so the proxy can serve HTTPS on port 443
# (Claude Code makes hardcoded HTTPS calls to api.anthropic.com that
# bypass ANTHROPIC_BASE_URL — the network alias routes them here)
RUN openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
    -days 3650 -nodes -subj '/CN=api.anthropic.com' \
    -addext 'subjectAltName=DNS:api.anthropic.com,DNS:statsig.anthropic.com,DNS:sentry.anthropic.com'

COPY proxy.js .

EXPOSE 8080 443

CMD ["node", "proxy.js"]

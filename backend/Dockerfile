FROM node:20.14.0-alpine3.20

# Install additional tools needed for node-pty
RUN apk add --no-cache python3 make g++ linux-headers

WORKDIR /app

# Copy package files first for better layer caching
COPY package*.json ./
RUN npm install --omit=dev

# Copy TypeScript source and build
COPY tsconfig.json ./
COPY src/ ./src/
RUN npm install --save-dev typescript tsx @types/node @types/express @types/jsonwebtoken @types/pg @types/uuid @types/ws && \
    npm run build

# Remove devDependencies after build
RUN npm prune --omit=dev

# Run as non-root
RUN addgroup -g 1001 netlab && adduser -u 1001 -G netlab -s /bin/sh -D netlab

# The backend needs to read the kubeconfig — it's mounted as a volume
# The /root/.kube mount works if running as root; switch to explicit path
USER netlab

EXPOSE 4000

# Memory limit enforced via NODE_OPTIONS env var (set in .env / compose)
ENV NODE_OPTIONS="--max-old-space-size=256"

HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=3 \
    CMD wget -qO- http://localhost:4000/health || exit 1

CMD ["node", "dist/index.js"]

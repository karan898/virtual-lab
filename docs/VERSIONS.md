# VERSIONS.md — Pinned versions for all components

All versions are pinned to ensure reproducibility. This file is the authoritative
reference for the research paper's software environment section.

---

## Base Image

| Component | Version / Tag | Digest |
|-----------|--------------|--------|
| Ubuntu base (lab-node) | `ubuntu:24.04` | `sha256:b59d21599a2b151e23eea5f6602f4af4d7d31c4e236d22bf0b62b86d2e386b8f` |

## Host Environment (WSL2)

| Component | Version |
|-----------|---------|
| WSL2 kernel | `6.6.114.1-microsoft-standard-WSL2` |
| WSL2 distro | Ubuntu 24.04 (Noble Numbat) |
| Docker Engine | `29.1.3` |
| OS | Ubuntu 24.04 (Noble) |

## Container Images (docker-compose)

| Service | Image | Tag |
|---------|-------|-----|
| PostgreSQL | `postgres` | `16.3-alpine3.20` |
| Redis | `redis` | `7.2.5-alpine3.20` |
| Kafka (KRaft) | `apache/kafka` | `3.7.0` |
| Prometheus | `prom/prometheus` | `v2.52.0` |
| Grafana | `grafana/grafana` | `10.4.2` |
| Frontend (nginx) | `nginx` | `1.27.0-alpine3.19` |

## Kubernetes / Orchestration

| Component | Version |
|-----------|---------|
| kind | `0.23.0` |
| kubectl | `1.30.2` |
| Kubernetes (inside kind) | `1.30.2` |

## lab-node Packages (from Ubuntu 24.04 apt — verified 2026-09-28)

| Package | Installed version |
|---------|-------------------|
| frr | **8.4.4** (Ubuntu 24.04 package — NOT 10.1 as initially assumed; see DEVIATIONS.md) |
| frr-pythontools | 8.4.4 |
| openvswitch-switch | **3.3.9** |
| openvswitch-common | 3.3.9 |
| iproute2 | (from Ubuntu 24.04 base) |
| iputils-ping | (from Ubuntu 24.04 base) |
| tcpdump | (from Ubuntu 24.04 base) |

## Backend (Node.js)

| Package | Version |
|---------|---------|
| Node.js | `20.14.0 LTS` |
| TypeScript | `5.4.5` |
| dotenv | `16.4.5` |
| express | `4.19.2` |
| @kubernetes/client-node | `0.21.0` |
| jsonwebtoken | `9.0.2` |
| argon2 | `0.31.2` |
| pg (node-postgres) | `8.11.5` |
| ioredis | `5.4.1` |
| kafkajs | `2.2.4` |
| prom-client | `15.1.2` |
| ws (WebSocket) | `8.17.1` |
| express-rate-limit | `7.3.1` |
| zod | `3.23.8` |

## Frontend

| Package | Version |
|---------|---------|
| React | `18.3.1` |
| Vite | `5.3.1` |
| xterm.js | `5.3.0` |
| xterm-addon-fit | `0.8.0` |
| react-router-dom | `6.24.0` |
| axios | `1.7.2` |
| @xyflow/react (topology graph) | `12.0.0` |

## Benchmark

| Package | Version |
|---------|---------|
| tsx | `4.15.6` |
| ws | `8.17.1` |
| csv-stringify | `6.4.6` |
| commander | `12.1.0` |

| node-pty | `1.0.0` |
| uuid | `9.0.1` |

## Benchmark

| Package | Version |
|---------|---------|
| tsx | `4.15.6` |
| ws | `8.17.1` |
| csv-stringify | `6.4.6` |
| commander | `12.1.0` |

---

*Last updated: 2026-09-29 (Phase 2)*  
*To regenerate: `make versions`*

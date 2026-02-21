# Iran Survival Pack

Self-hosted services for restricted environments. All traffic uses Iranian mirrors (Arvan Cloud + focker.ir).

## Quick Start

```bash
# 1. Setup server (apt mirrors, docker, nginx, firewall, IP/domain)
make init

# 2. Deploy Jitsi Meet video conferencing
make jitsi
```

## Ports

| Port | Protocol | Service |
|-------|----------|-----------------|
| 80 | TCP | HTTP redirect |
| 443 | TCP | HTTPS (Jitsi) |
| 10000 | UDP | Jitsi media |
| 22 | TCP | SSH |

## Requirements

- Ubuntu 22.04+ or Debian 11+
- Root / sudo access

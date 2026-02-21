# Iran Survival Pack

Self-hosted services for restricted environments. All traffic uses Iranian mirrors.

## Quick Start

```bash
# 1. Setup server (DNS, apt mirrors, docker, nginx, firewall, IP/domain)
make init

# 2. Deploy Jitsi Meet video conferencing (on /)
make jitsi

# 3. Deploy Mattermost team chat (on /chat)
make chat
```

## Ports

| Port | Protocol | Service |
|-------|----------|-----------------|
| 80 | TCP | HTTP redirect |
| 443 | TCP | HTTPS |
| 10000 | UDP | Jitsi media |
| 8443 | TCP/UDP | Mattermost Calls |
| 22 | TCP | SSH |

## Requirements

- Ubuntu 22.04+ or Debian 11+
- Root / sudo access

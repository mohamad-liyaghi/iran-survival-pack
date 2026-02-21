# Iran Survival Pack

Self-hosted services for restricted environments. All traffic uses Iranian mirrors.

## Quick Start

```bash
# 1. Setup server (DNS, apt mirrors, docker, nginx, firewall, IP/domain)
make init

# 2. Deploy Jitsi Meet video conferencing (on /)
make jitsi

# 3. Deploy Mattermost team chat (port 8090)
make chat

# 4. Deploy File Browser - web file manager (port 8091)
make sftp
```

## Ports

| Port | Protocol | Service |
|-------|----------|----------------------|
| 80 | TCP | HTTP (Jitsi redirect) |
| 443 | TCP | HTTPS (Jitsi) |
| 8090 | TCP | Mattermost chat |
| 10000 | UDP | Jitsi media |
| 8445 | TCP/UDP | Mattermost Calls |
| 8091 | TCP | File Browser |
| 22 | TCP | SSH |

## Requirements

- Ubuntu 22.04+ or Debian 11+
- Root / sudo access

# Iran Survival Pack

---

A set of self-hosted services you can run on your own server in Iran.  
No blocked domains, no foreign cloud, no data leaving your hands.

Everything installs from Iranian mirrors. Docker images come from Arvan Cloud.  
DNS is automatically set to anti-sanction resolvers during `make init`.

**Includes:**
- Video conferencing (Jitsi Meet)
- Team chat (Mattermost)
- Web file manager (File Browser)
- Git repository hosting (Forgejo)
- Docker registry (Harbor)

---

## Requirements

- Ubuntu 22.04+ or Debian 11+
- A VPS or dedicated server with a public IP
- Root or sudo access
- The repo cloned on the server:

```bash
git clone https://github.com/mohamad-liyaghi/iran-survival-pack.git
cd iran-survival-pack
```

---

## Setup

### 1. `make init`

Run this once before anything else.

- Switches apt to Iranian mirrors (Runflare, 10.ir CDN)
- Sets DNS to 403.online + Shekan (so Docker and apt can reach sanctioned repos)
- Installs Docker, Nginx, firewall
- Asks for your server IP and domain — saved to `config.json`

```bash
make init
```

---

### 2. `make cert` _(optional — only if you have a domain)_

Skip this if you're using a plain IP. Run it if you want a real trusted certificate for your subdomains.

Uses Let's Encrypt with DNS-01 challenge — works from Iran. No browser warnings, no CA installation on devices.

```bash
make cert
```

---

### 3. `make jitsi`

Encrypted video conferencing.

- 2-person calls use P2P (no server relay needed)
- Group calls go through the JVB media bridge
- Asks if you want a self-signed SSL certificate (recommended — required for mic/camera)
- If you set a domain in `make init`, it uses `meet.yourdomain.com` and asks you to add the DNS record first

**Without a domain:** accessible at `https://YOUR_IP`  
**With a domain:** accessible at `https://meet.yourdomain.com`

```bash
make jitsi
```

Ports: `80`, `443`, `10000/udp`

---

### 4. `make chat`

Team messaging, channels, file sharing.

- Runs Mattermost Team Edition (free, no user limit)
- PostgreSQL database included
- On first visit, create your admin account
- If you set a domain, it uses `chat.yourdomain.com` — otherwise `http://YOUR_IP:8090`

```bash
make chat
```

Ports: `8090` (IP mode) or `80/443` (domain mode), `8445/udp` for voice calls

---

### 5. `make sftp`

Web-based file manager — upload, download, share files from any browser.

- Clean UI with drag & drop, batch download, zip/unzip
- Multi-user: create users and set permissions from the admin panel
- Default login: `admin` / (password shown in terminal after setup — change it)
- If you set a domain, it uses `files.yourdomain.com` — otherwise `http://YOUR_IP:8091`

```bash
make sftp
```

Ports: `8091` (IP mode) or `80/443` (domain mode)

---

### 6. `make git`

Self-hosted Git — repositories, issues, pull requests, CI/CD.

- Forgejo (Gitea fork, lightweight, ~100MB RAM)
- PostgreSQL database included
- Git SSH access on port `2222`
- First registered user becomes admin
- If you set a domain, it uses `git.yourdomain.com` — otherwise `http://YOUR_IP:8092`

```bash
make git
```

Ports: `8092` (IP mode) or `80/443` (domain mode), `2222` for Git SSH

---

### 7. `make registry`

Private Docker registry with web UI, vulnerability scanning, access control.

- Harbor with Trivy scanner
- Push/pull images like Docker Hub but on your own server
- Role-based access, project quotas, audit logs
- If you set a domain, it uses `hub.yourdomain.com` — otherwise `http://YOUR_IP:8093`

```bash
make registry
```

Ports: `8093` (IP mode) or `80/443` (domain mode)

---

## Ports

| Port | Use |
|------|-----|
| 22 | SSH |
| 80 | HTTP / redirect to HTTPS |
| 443 | HTTPS (all services — domain mode) |
| 2222 | Forgejo Git SSH |
| 8090 | Mattermost (IP mode only) |
| 8091 | File Browser (IP mode only) |
| 8092 | Forgejo (IP mode only) |
| 8093 | Harbor (IP mode only) |
| 10000/udp | Jitsi audio/video |
| 8445/udp | Mattermost voice calls |

---

## Domain mode vs IP mode

If you entered a real domain in `make init`, each service gets its own subdomain:

| Service | Subdomain |
|---------|-----------|
| Jitsi | `meet.yourdomain.com` |
| Mattermost | `chat.yourdomain.com` |
| File Browser | `files.yourdomain.com` |
| Forgejo | `git.yourdomain.com` |
| Harbor | `hub.yourdomain.com` |

You'll be prompted to add an `A` record for each subdomain before setup continues.

If you only have an IP, everything runs on separate ports — no DNS needed.

---

## SSL Certificates

You have two options:

**Option A — Real Let's Encrypt cert (recommended):**

```bash
make cert
```

Uses `acme.sh` with DNS-01 challenge. Works from Iran because Let's Encrypt verifies a DNS TXT record — it never connects to your server. Supports Cloudflare (automatic) or any DNS provider (manual TXT record). After this, all three subdomains get a trusted green lock with zero browser warnings.

**Option B — Self-signed cert:**

Generated automatically when you run `make jitsi`/`make chat`/`make sftp`. A local CA signs a wildcard cert for `*.yourdomain.com`. Browser shows a warning — click **Advanced → Proceed**.  
To remove the warning permanently, download `https://meet.yourdomain.com/ca.crt` and install the CA cert on each device.

**If you see the HSTS error in Chrome (can't click "Advanced"):**  
Go to `chrome://net-internals/#hsts` → under "Delete domain security policies" → type your domain → click **Delete**. Then try again.

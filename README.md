# Iran Survival Pack

**[برای مشاهده مستندات فارسی اینجا کلیک کنید ↓](#فارسی)**

---

A set of self-hosted services you can run on your own server in Iran.  
No blocked domains, no foreign cloud, no data leaving your hands.

Everything installs from Iranian mirrors. Docker images come from Arvan Cloud.  
DNS is automatically set to anti-sanction resolvers during `make init`.

**Includes:**
- Video conferencing (Jitsi Meet)
- Team chat (Mattermost)
- Web file manager (File Browser)

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

### 2. `make cert` (optional but recommended)

Get a real Let's Encrypt wildcard cert. Works from Iran — no server access needed from Let's Encrypt, it only checks a DNS TXT record you add.

- Cloudflare: fully automatic, just paste your API token
- Any other DNS provider: manual mode — adds the TXT record yourself

```bash
make cert
```

After this: `meet.`, `chat.`, `files.` all have a trusted green lock — no warnings, no CA cert installation on devices, no HSTS issues ever.

---

### 3. `make jitsi` (after `make cert`)

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

## Ports

| Port | Use |
|------|-----|
| 22 | SSH |
| 80 | HTTP / redirect to HTTPS |
| 443 | HTTPS (Jitsi, Mattermost, Files — domain mode) |
| 8090 | Mattermost (IP mode only) |
| 8091 | File Browser (IP mode only) |
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

---
---

<div dir="rtl" id="فارسی">

# فارسی

**بسته بقا برای ایران** — سرویس‌هایی که روی سرور خودت اجرا می‌شن، بدون نیاز به اینترنت آزاد.

همه چیز از میرورهای ایرانی نصب می‌شه. ایمیج‌های داکر از ارون کلاد کشیده می‌شن.
DNS به صورت خودکار روی سرورهای ضد تحریم تنظیم می‌شه.

**سرویس‌ها:**
- ویدیوکنفرانس (Jitsi Meet)
- پیام‌رسان تیمی (Mattermost)
- مدیر فایل تحت وب (File Browser)

---

## پیش‌نیازها

- Ubuntu 22.04+ یا Debian 11+
- سرور با IP عمومی
- دسترسی root یا sudo
- کلون کردن ریپو روی سرور:

```bash
git clone https://github.com/mohamad-liyaghi/iran-survival-pack.git
cd iran-survival-pack
```

---

## دستورات

### `make init`
یک بار اجرا کن، قبل از همه چیز.

- منابع apt رو به میرورهای ایرانی تغییر می‌ده
- DNS ضد تحریم تنظیم می‌کنه (403.online + شکن)
- داکر، Nginx، فایروال نصب می‌کنه
- IP و دامنه سرورت رو می‌پرسه

```bash
make init
```

---

### `make jitsi`
ویدیوکنفرانس رمزنگاری‌شده.

- تماس دو نفره: مستقیم بین مرورگرها (P2P)
- تماس گروهی: از طریق JVB
- گواهی SSL خودامضا می‌سازه (برای میکروفون/دوربین ضروریه)
- اگه دامنه داری: روی `meet.yourdomain.com` اجرا می‌شه

```bash
make jitsi
```

---

### `make chat`
پیام‌رسان تیمی.

- Mattermost رایگان، کاربر نامحدود
- کانال، پیام مستقیم، اشتراک‌گذاری فایل
- اولین بار که باز می‌کنی، اکانت ادمین می‌سازی
- اگه دامنه داری: روی `chat.yourdomain.com` اجرا می‌شه

```bash
make chat
```

---

### `make cert`
گواهی SSL واقعی از Let's Encrypt.

- از DNS-01 استفاده می‌کنه — نیازی نیست Let's Encrypt به سرورت وصل بشه
- از ایران کار می‌کنه — تحریم مشکلی نیست
- از Cloudflare یا هر پنل DNS دیگه‌ای پشتیبانی می‌کنه
- بعد از نصب، هر سه سرویس قفل سبز دارن — بدون هیچ هشداری

```bash
make cert
```

---

### `make sftp`
مدیر فایل تحت وب.

- رابط کاربری ساده با drag & drop
- چند کاربر با سطح دسترسی مختلف
- لاگین پیش‌فرض: `admin` — پسورد توی ترمینال نشون داده می‌شه، بعد از اولین ورود عوضش کن
- اگه دامنه داری: روی `files.yourdomain.com` اجرا می‌شه

```bash
make sftp
```

---

## دامنه یا IP؟

اگه توی `make init` یه دامنه وارد کردی، هر سرویس روی ساب‌دامین خودش اجرا می‌شه:

| سرویس | آدرس |
|-------|------|
| Jitsi | `meet.yourdomain.com` |
| Mattermost | `chat.yourdomain.com` |
| File Browser | `files.yourdomain.com` |

قبل از اجرای هر سرویس، باید یه رکورد `A` برای ساب‌دامین اضافه کنی.
اگه فقط IP داری، همه چیز روی پورت‌های جداگانه اجرا می‌شه.

</div>

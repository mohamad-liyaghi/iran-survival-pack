# Iran Survival Pack

> **Survival tools for living in Iran without open internet.**
> Self-hosted, censorship-resistant services that run entirely on your own server —
> no foreign SaaS, no blocked domains, no data leaving your hands.
>
> All packages use Iranian mirrors (Runflare, 10.ir CDN).
> All Docker images use Arvan Cloud registry.
> DNS is set to anti-sanction resolvers (403.online + Shekan) automatically.

---

## Prerequisites

- A **Linux server** (Ubuntu 22.04+ or Debian 11+) with a public IP
- **Root / sudo** access
- The repo cloned on the server:
  ```bash
  git clone https://github.com/YOUR_USERNAME/iran-survival-pack.git
  cd iran-survival-pack
  ```

---

## Commands

### `make init`
**Run this first — one time only.**

Sets up the entire server:
- Switches apt sources to Iranian mirrors (Runflare / 10.ir CDN)
- Sets anti-sanction DNS (403.online + Shekan + Google fallback)
- Installs Docker (via official apt repo, falls back to get.docker.com or snap)
- Configures Docker to pull images from Arvan Cloud registry
- Installs Nginx
- Configures firewall (ufw)
- Asks for your server's **public IP** and **domain** — saves to `config.json`

```bash
make init
```

---

### `make jitsi`
**Encrypted video conferencing — like Zoom, but yours.**

- Accessible at `https://YOUR_DOMAIN` (port 443)
- Supports 2-person P2P calls (direct, no server in the middle)
- Supports group calls through JVB media bridge
- Asks whether to generate a self-signed SSL certificate
- Configures Nginx with proper WebSocket proxying for audio/video

**Ports used:** `80`, `443`, `10000/udp`

```bash
make jitsi
```

---

### `make chat`
**Team messaging — like Slack/Teams, but yours.**

- Accessible at `http://YOUR_DOMAIN:8090`
- Mattermost Team Edition (free, unlimited users)
- Channels, direct messages, file sharing, notifications
- PostgreSQL database included
- Create your admin account on first visit

**Ports used:** `8090`, `8445/udp` (voice calls)

```bash
make chat
```

---

### `make sftp`
**Web file manager — upload, download, share files from a browser.**

- Accessible at `http://YOUR_DOMAIN:8091`
- Clean web UI — drag & drop upload, batch download, folder management
- Multi-user with individual permissions (admin / editor / viewer)
- Manage users from **Settings → User Management** in the web UI
- Default login: `admin` / (password shown in terminal after setup)

**Ports used:** `8091`

```bash
make sftp
```

---

## Port Reference

| Port | Protocol | Service |
|------|----------|--------------------------|
| 22 | TCP | SSH |
| 80 | TCP | HTTP → HTTPS redirect |
| 443 | TCP | Jitsi Meet (HTTPS) |
| 8090 | TCP | Mattermost chat |
| 8091 | TCP | File Browser |
| 10000 | UDP | Jitsi media (audio/video) |
| 8445 | TCP/UDP | Mattermost Calls |

---

## Notes

- Re-running any `make` command is safe — it will reconfigure and restart the service.
- Config is stored in `config.json` (gitignored).
- To add a new Jitsi WebSocket or service to Nginx, drop a `.conf` file in `/etc/nginx/survival-pack.d/`.

---

<div dir="rtl">

# بسته بقا برای ایران

> **ابزارهای بقا برای زندگی در ایران بدون اینترنت آزاد.**
> سرویس‌هایی که کاملاً روی سرور خودت اجرا می‌شن —
> بدون SaaS خارجی، بدون دامنه‌های مسدود، بدون خروج داده.
>
> تمام پکیج‌ها از میرور ایرانی (Runflare، CDN ۱۰.ir) نصب می‌شن.
> تمام ایمیج‌های داکر از رجیستری ارون کلاد کشیده می‌شن.
> DNS به صورت خودکار روی سرورهای ضد تحریم (403.online + شکن) تنظیم می‌شه.

---

## پیش‌نیازها

- یک **سرور لینوکسی** (Ubuntu 22.04+ یا Debian 11+) با IP عمومی
- دسترسی **root / sudo**
- ریپو کلون‌شده روی سرور:
  ```bash
  git clone https://github.com/YOUR_USERNAME/iran-survival-pack.git
  cd iran-survival-pack
  ```

---

## دستورات

### `make init`
**اول از همه — یک بار اجرا کن.**

کل سرور رو آماده می‌کنه:
- منابع apt رو به میرورهای ایرانی تغییر می‌ده (Runflare / CDN 10.ir)
- DNS ضد تحریم تنظیم می‌کنه (403.online + شکن + Google fallback)
- داکر نصب می‌کنه (از ریپوی رسمی، با fallback به get.docker.com یا snap)
- داکر رو روی رجیستری ارون کلاد تنظیم می‌کنه
- Nginx نصب می‌کنه
- فایروال (ufw) تنظیم می‌کنه
- IP عمومی و دامنه سرورت رو می‌پرسه — توی `config.json` ذخیره می‌شه

```bash
make init
```

---

### `make jitsi`
**ویدیوکنفرانس رمزنگاری‌شده — مثل Zoom، ولی مال خودت.**

- دسترسی از `https://دامنه‌ات` (پورت ۴۴۳)
- تماس دو نفره P2P (مستقیم، بدون سرور واسط)
- تماس گروهی از طریق JVB
- می‌پرسه آیا گواهی SSL خودامضا بسازه یا نه
- Nginx با WebSocket درست برای صدا/تصویر تنظیم می‌شه

**پورت‌ها:** `80`، `443`، `10000/udp`

```bash
make jitsi
```

---

### `make chat`
**پیام‌رسان تیمی — مثل Slack، ولی مال خودت.**

- دسترسی از `http://دامنه‌ات:8090`
- Mattermost Team Edition (رایگان، کاربر نامحدود)
- کانال، پیام مستقیم، اشتراک‌گذاری فایل، اعلان
- دیتابیس PostgreSQL داخل داکر
- اولین بار که باز می‌کنی اکانت ادمین می‌سازی

**پورت‌ها:** `8090`، `8445/udp` (تماس صوتی)

```bash
make chat
```

---

### `make sftp`
**مدیر فایل تحت وب — آپلود، دانلود، اشتراک فایل از مرورگر.**

- دسترسی از `http://دامنه‌ات:8091`
- رابط کاربری ساده — drag & drop، دانلود دسته‌ای، مدیریت پوشه
- چند کاربر با سطوح دسترسی مختلف (ادمین / ویرایشگر / بیننده)
- مدیریت کاربران از **Settings → User Management** در پنل وب
- لاگین پیش‌فرض: `admin` / (پسورد توی ترمینال نشون داده می‌شه)

**پورت‌ها:** `8091`

```bash
make sftp
```

---

## پورت‌ها

| پورت | پروتکل | سرویس |
|------|---------|--------|
| 22 | TCP | SSH |
| 80 | TCP | HTTP → ریدایرکت HTTPS |
| 443 | TCP | Jitsi Meet |
| 8090 | TCP | Mattermost |
| 8091 | TCP | مدیر فایل |
| 10000 | UDP | Jitsi میدیا (صدا/تصویر) |
| 8445 | TCP/UDP | تماس صوتی Mattermost |

</div>

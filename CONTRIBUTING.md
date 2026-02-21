# Contributing

Contributions are welcome. This project is for people running services on Iranian servers, so practical fixes and real-world improvements matter most.

## What's useful

- Fixes for services that break due to sanctions or blocked domains
- New Iranian mirrors or DNS resolvers that work better
- Support for more Linux distributions
- New self-hosted services that follow the same pattern
- Documentation improvements (both English and Persian)

## How to contribute

1. Fork the repo and create a branch
2. Make your changes
3. Test on a real Iranian server if possible — local testing won't catch mirror/DNS issues
4. Open a pull request with a clear description of what changed and why

## Adding a new service

Each service lives in its own folder and follows this structure:

```
myservice/
  setup.sh          # main setup script
  docker-compose.yml
  .env.template     # variables with __PLACEHOLDERS__ replaced by setup.sh
```

`setup.sh` should:

- Read `config.json` for `server_ip` and `domain`
- Detect IP vs domain mode and adjust ports/subdomains accordingly
- Reuse the shared cert at `/etc/nginx/ssl/survival-pack/cert.pem` if it exists
- Write its own Nginx config to `/etc/nginx/sites-available/` and symlink it
- Open only the ports it needs via `ufw`
- Pull images from `docker.arvancloud.ir` (Arvan Cloud mirror) to avoid Docker Hub blocks
- Print clear instructions at the end including the URL and any credentials

Add `make myservice` to the `Makefile` and document it in `README.md`.

## Code style

- Bash scripts use `set -euo pipefail`
- No hardcoded `/opt` paths — use `${HOME}/...` instead (some servers have read-only `/opt`)
- Passwords generated with `openssl rand -hex N`, not `tr`/`head` pipes (avoids SIGPIPE)
- Keep scripts readable — avoid one-liners that obscure what's happening

## Questions

Open an issue or reach out via GitHub: [@mohamad-liyaghi](https://github.com/mohamad-liyaghi)

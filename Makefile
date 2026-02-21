.PHONY: init cert jitsi chat sftp git registry

help:
	@echo "Usage: make <target>"
	@echo "Targets:"
	@echo "  init     - Initialize the server"
	@echo "  cert     - Generate a Let's Encrypt certificate (if you have a domain)"
	@echo "  jitsi    - Setup Jitsi Meet (Google meet alternative)"
	@echo "  chat     - Setup Mattermost (Slack alternative)"
	@echo "  sftp     - Setup File Browser (Web file manager)"
	@echo "  git      - Setup Forgejo (Github alternative)"
	@echo "  registry - Setup Harbor (Docker registry alternative)"

init:
	@sudo bash init.sh

cert:
	@sudo bash cert/setup.sh

jitsi:
	@sudo bash jitsi/setup.sh

chat:
	@sudo bash mattermost/setup.sh

sftp:
	@sudo bash sftp/setup.sh

git:
	@sudo bash forgejo/setup.sh

registry:
	@sudo bash harbor/setup.sh

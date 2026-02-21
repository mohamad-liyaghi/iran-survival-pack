.PHONY: init cert jitsi chat sftp git registry

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

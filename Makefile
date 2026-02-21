.PHONY: init jitsi chat sftp

init:
	@sudo bash init.sh

jitsi:
	@sudo bash jitsi/setup.sh

chat:
	@sudo bash mattermost/setup.sh

sftp:
	@sudo bash sftp/setup.sh

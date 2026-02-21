.PHONY: init jitsi chat

init:
	@sudo bash init.sh

jitsi:
	@sudo bash jitsi/setup.sh

chat:
	@sudo bash mattermost/setup.sh

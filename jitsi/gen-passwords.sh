#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

generate_password() {
    openssl rand -hex 16
}

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: ${ENV_FILE} not found"
    exit 1
fi

VARS=(
    JICOFO_AUTH_PASSWORD
    JVB_AUTH_PASSWORD
    JIGASI_XMPP_PASSWORD
    JIGASI_TRANSCRIBER_PASSWORD
    JIBRI_RECORDER_PASSWORD
    JIBRI_XMPP_PASSWORD
)

for VAR in "${VARS[@]}"; do
    PASS=$(generate_password)
    sed -i "s|^${VAR}=.*|${VAR}=${PASS}|" "$ENV_FILE"
done

echo "Passwords written to ${ENV_FILE}"

#!/usr/bin/env bash
# Example notification hook for pve-ct-autoupdate.sh
#
# Install as /usr/local/bin/pve-ct-autoupdate-notify.sh (or point
# PVE_AUTOUPDATE_NOTIFY_CMD at it) and it will be picked up automatically.
#
# Called as: notify.sh <severity> <title> <message>
#   severity: info | warning | error
#
# Only updates and failures reach this hook: a run with nothing to do never
# calls it.

set -u

NTFY_URL=${NTFY_URL:-https://ntfy.example.com}     # <-- set your own server + topic
NTFY_TOPIC=${NTFY_TOPIC:-mytopic}

severity=${1:-info}
title=${2:-pve-ct-autoupdate}
message=${3:-}

case $severity in
    error)   priority=high;   tags=warning_triangle ;;
    warning) priority=medium; tags=warning ;;
    *)       priority=low;    tags=check_mark_button ;;
esac

curl -s -f \
    -H "Title: $title" \
    -H "Priority: $priority" \
    -H "Tags: $tags" \
    -d "$message" \
    "$NTFY_URL/$NTFY_TOPIC" > /dev/null

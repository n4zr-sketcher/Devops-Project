#!/usr/bin/env bash
# systemctl-shim for containerized Ubuntu 22.04 target
ACTION="${1:-}"
SERVICE="${2:-}"

case "$ACTION" in
    reload|restart)
        nginx -t >/dev/null 2>&1 && nginx -s reload 2>/dev/null || nginx
        exit 0
        ;;
    is-active|status)
        if pgrep -x nginx >/dev/null 2>&1; then
            exit 0
        elif [ -f /var/run/nginx.pid ]; then
            exit 0
        else
            exit 1
        fi
        ;;
    enable|disable|start|stop)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac

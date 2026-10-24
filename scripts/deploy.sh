#!/usr/bin/env bash
###############################################################################
# deploy.sh
#
# Publishes a new release of the web application ON THE AZURE VM.
#
# The Jenkins pipeline uploads both the application files and this script to a
# temporary folder on the VM and then runs it with sudo:
#
#   sudo bash /tmp/cicd-build-<n>/deploy.sh /tmp/cicd-build-<n>/app
#
# Design goals
#   * ZERO DOWNTIME - the new files are staged in a separate folder, the
#     Nginx configuration is validated, and only then is the live symlink
#     swapped and Nginx RELOADED (a reload keeps existing connections alive;
#     a restart would drop them).
#   * ROLLBACK READY - every release stays in its own folder, so a previous
#     version can be re-activated in seconds.
#   * SAFE - an invalid Nginx configuration aborts the deployment BEFORE the
#     live site is touched, and a missing index.html aborts immediately.
###############################################################################
set -Eeuo pipefail

# --------------------------------------------------------------------------
# Configuration (override with environment variables if required)
# --------------------------------------------------------------------------
APP_SOURCE_DIR="${1:-}"
RELEASES_DIR="${RELEASES_DIR:-/var/www/releases}"
APP_LINK="${APP_LINK:-/var/www/app}"
NGINX_BIN="${NGINX_BIN:-/usr/sbin/nginx}"
NGINX_SERVICE="${NGINX_SERVICE:-nginx}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
WEB_USER="${WEB_USER:-www-data}"
WEB_GROUP="${WEB_GROUP:-www-data}"
BUILD_TAG="${BUILD_TAG:-manual}"
BUILD_NUMBER="${BUILD_NUMBER:-0}"
GIT_COMMIT="${GIT_COMMIT:-unknown}"
DEPLOYED_BY="${DEPLOYED_BY:-unknown}"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
log()  { printf '[deploy] %s\n' "$*"; }
warn() { printf '[deploy] WARNING: %s\n' "$*" >&2; }
die()  { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }
trap 'die "aborted at line $LINENO (command: $BASH_COMMAND)"' ERR

# --------------------------------------------------------------------------
# 0. Pre-flight checks
# --------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "this script must run as root (use sudo)."
[ -n "${APP_SOURCE_DIR}" ] || die "usage: deploy.sh <path-to-app-folder>"
[ -d "${APP_SOURCE_DIR}" ] || die "source directory '${APP_SOURCE_DIR}' does not exist."
[ -f "${APP_SOURCE_DIR}/index.html" ] || \
    die "'${APP_SOURCE_DIR}/index.html' is missing - refusing to deploy an incomplete application."

log "starting deployment"
log "  source     : ${APP_SOURCE_DIR}"
log "  releases   : ${RELEASES_DIR}"
log "  live path  : ${APP_LINK}"
log "  build      : ${BUILD_TAG} (#${BUILD_NUMBER}, commit ${GIT_COMMIT})"

# --------------------------------------------------------------------------
# 1. Stage the new release in its own immutable folder
# --------------------------------------------------------------------------
# The release identifier must be unique even when two deployments land inside
# the same second. A plain timestamp is not enough: the second deployment
# would reuse the first release folder, rsync --delete would erase the
# previous release and the rollback history would be lost.
BASE_ID="$(date -u +%Y%m%d%H%M%S)"
RELEASE_ID="${BASE_ID}-$(printf '%04x' "$((RANDOM % 65536))")"
RELEASE_DIR="${RELEASES_DIR}/release-${RELEASE_ID}"

# Belt and braces: if that directory somehow already exists, add a counter.
COUNTER=1
while [ -e "${RELEASE_DIR}" ]; do
    RELEASE_DIR="${RELEASES_DIR}/release-${RELEASE_ID}-${COUNTER}"
    COUNTER=$((COUNTER + 1))
done

log "staging release in ${RELEASE_DIR}"
mkdir -p "${RELEASE_DIR}"
if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "${APP_SOURCE_DIR}/" "${RELEASE_DIR}/"
else
    cp -a "${APP_SOURCE_DIR}/." "${RELEASE_DIR}/"
fi

# --------------------------------------------------------------------------
# 2. Build metadata - served by Nginx at /build-info.txt
# --------------------------------------------------------------------------
cat > "${RELEASE_DIR}/build-info.txt" <<EOF
build_number=${BUILD_NUMBER}
build_tag=${BUILD_TAG}
git_commit=${GIT_COMMIT}
deployed_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
release_id=${RELEASE_ID}
deployed_by=${DEPLOYED_BY}
EOF

# --------------------------------------------------------------------------
# 3. Ownership and permissions
# --------------------------------------------------------------------------
log "setting ownership to ${WEB_USER}:${WEB_GROUP}"
chown -R "${WEB_USER}:${WEB_GROUP}" "${RELEASE_DIR}"
find "${RELEASE_DIR}" -type d -exec chmod 755 {} +
find "${RELEASE_DIR}" -type f -exec chmod 644 {} +

# --------------------------------------------------------------------------
# 4. Validate the Nginx configuration BEFORE switching anything
# --------------------------------------------------------------------------
log "validating nginx configuration"
"${NGINX_BIN}" -t

# --------------------------------------------------------------------------
# 5. Atomically point the live symlink at the new release
# --------------------------------------------------------------------------
if [ -L "${APP_LINK}" ]; then
    ln -sfn "${RELEASE_DIR}" "${APP_LINK}.new"
    mv -Tf "${APP_LINK}.new" "${APP_LINK}"
elif [ -e "${APP_LINK}" ]; then
    # First deployment: the cloud-init placeholder is a real directory.
    MIGRATED="${RELEASES_DIR}/initial-$(date -u +%Y%m%d%H%M%S)"
    warn "${APP_LINK} is a real directory (first deployment) - moving it to ${MIGRATED}"
    mv "${APP_LINK}" "${MIGRATED}"
    ln -sfn "${RELEASE_DIR}" "${APP_LINK}.new"
    mv -Tf "${APP_LINK}.new" "${APP_LINK}"
else
    ln -sfn "${RELEASE_DIR}" "${APP_LINK}"
fi
log "live symlink now -> $(readlink -f "${APP_LINK}")"

# --------------------------------------------------------------------------
# 6. Graceful reload - live connections are NOT interrupted
# --------------------------------------------------------------------------
log "reloading nginx (graceful, zero downtime)"
systemctl reload "${NGINX_SERVICE}"
systemctl is-active --quiet "${NGINX_SERVICE}" || die "nginx is not active after the reload."

# --------------------------------------------------------------------------
# 7. Local verification
# --------------------------------------------------------------------------
log "verifying the site locally"
curl -fsS --max-time 15 http://127.0.0.1/health >/dev/null || \
    die "the /health endpoint did not respond - the deployment was rolled back."

# --------------------------------------------------------------------------
# 8. Housekeeping - keep only the newest KEEP_RELEASES folders
# --------------------------------------------------------------------------
mapfile -t OLD_RELEASES < <(
    find "${RELEASES_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | tail -n "+$((KEEP_RELEASES + 1))" | cut -d' ' -f2-
)
for old_release in "${OLD_RELEASES[@]:-}"; do
    [ -n "${old_release}" ] || continue
    log "removing old release ${old_release}"
    rm -rf "${old_release}"
done

# --------------------------------------------------------------------------
# 9. Summary
# --------------------------------------------------------------------------
log "DEPLOYMENT SUCCESSFUL"
log "  release   : ${RELEASE_DIR}"
log "  live path : ${APP_LINK} -> $(readlink -f "${APP_LINK}")"
log "  build     : ${BUILD_TAG} (#${BUILD_NUMBER}, commit ${GIT_COMMIT})"
log "  nginx     : $(systemctl is-active "${NGINX_SERVICE}")"
exit 0

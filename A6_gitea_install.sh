#!/bin/bash
# =============================================================================
# A1_gitea_install.sh - Gitea 설치 (Harbor VM 동거)
#
# 실행 위치: Harbor 서버 (10.1.5.10), 인터넷 환경에서 실행
#
# 설치 내용:
#   - Gitea v1.25.4 (Docker)
#   - 포트: 3000 (HTTP), 2222 (SSH)
#   - 데이터: /data/gitea
#   - 관리자 계정: 환경변수로 주입 가능
#
# 실행:
#   bash A1_gitea_install.sh
#   GITEA_ADMIN_PASSWORD="원하는패스워드" bash A1_gitea_install.sh
# =============================================================================
set -euo pipefail

# ★ 버전 고정값
GITEA_VERSION="1.25.4"
GITEA_IMAGE="gitea/gitea:${GITEA_VERSION}"

# ★ 설정값 (환경변수로 override 가능)
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-gitea}"
GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-Gitea12345}"   # ★ 변경 권장
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-admin@miso.local}"
GITEA_DOMAIN="${GITEA_DOMAIN:-gitea.miso.local}"
GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-3000}"
GITEA_SSH_PORT="${GITEA_SSH_PORT:-2222}"
GITEA_DATA_DIR="${GITEA_DATA_DIR:-/data/gitea}"

echo "================================================================"
echo " Gitea ${GITEA_VERSION} 설치 시작"
echo " Domain : ${GITEA_DOMAIN}"
echo " Port   : ${GITEA_HTTP_PORT} (HTTP), ${GITEA_SSH_PORT} (SSH)"
echo " Data   : ${GITEA_DATA_DIR}"
echo "================================================================"

# -----------------------------------------------------------------
# 1. 데이터 디렉토리 생성
# -----------------------------------------------------------------
echo "[1] 데이터 디렉토리 생성..."
sudo mkdir -p "${GITEA_DATA_DIR}"
sudo chown -R 1000:1000 "${GITEA_DATA_DIR}"

# -----------------------------------------------------------------
# 2. 기존 컨테이너 정리
# -----------------------------------------------------------------
echo "[2] 기존 Gitea 컨테이너 정리..."
sudo docker stop gitea 2>/dev/null || true
sudo docker rm gitea 2>/dev/null || true

# -----------------------------------------------------------------
# 3. Gitea 이미지 pull
# -----------------------------------------------------------------
echo "[3] Gitea 이미지 pull..."
sudo docker pull "${GITEA_IMAGE}"

# -----------------------------------------------------------------
# 4. Gitea 컨테이너 실행
# -----------------------------------------------------------------
echo "[4] Gitea 컨테이너 실행..."
sudo docker run -d \
  --name gitea \
  --restart unless-stopped \
  -e USER_UID=1000 \
  -e USER_GID=1000 \
  -e GITEA__server__DOMAIN="${GITEA_DOMAIN}" \
  -e GITEA__server__ROOT_URL="https://${GITEA_DOMAIN}" \
  -e GITEA__server__HTTP_PORT="${GITEA_HTTP_PORT}" \
  -e GITEA__server__SSH_PORT="${GITEA_SSH_PORT}" \
  -e GITEA__server__SSH_LISTEN_PORT="${GITEA_SSH_PORT}" \
  -e GITEA__database__DB_TYPE=sqlite3 \
  -e GITEA__database__PATH=/data/gitea/gitea.db \
  -e GITEA__security__INSTALL_LOCK=true \
  -e GITEA__service__DISABLE_REGISTRATION=true \
  -e GITEA__log__LEVEL=Info \
  -v "${GITEA_DATA_DIR}:/data" \
  -p "${GITEA_HTTP_PORT}:${GITEA_HTTP_PORT}" \
  -p "${GITEA_SSH_PORT}:22" \
  "${GITEA_IMAGE}"

# -----------------------------------------------------------------
# 5. 기동 대기
# -----------------------------------------------------------------
echo "[5] Gitea 기동 대기..."
for i in $(seq 1 30); do
  if curl -sf "http://localhost:${GITEA_HTTP_PORT}/api/v1/version" > /dev/null 2>&1; then
    echo "  ✓ Gitea 기동 완료"
    break
  fi
  echo "  대기 중... (${i}/30)"
  sleep 3
done

# -----------------------------------------------------------------
# 6. 관리자 계정 생성
# -----------------------------------------------------------------
echo "[6] 관리자 계정 생성..."
if sudo docker exec gitea gitea admin user list 2>/dev/null | grep -q "${GITEA_ADMIN_USER}"; then
  echo "  ✓ 관리자 계정 이미 존재: ${GITEA_ADMIN_USER}"
else
  sudo docker exec -u git gitea gitea admin user create \
    --username "${GITEA_ADMIN_USER}" \
    --password "${GITEA_ADMIN_PASSWORD}" \
    --email "${GITEA_ADMIN_EMAIL}" \
    --admin \
    --must-change-password=false
  echo "  ✓ 관리자 계정 생성: ${GITEA_ADMIN_USER}"
fi

# -----------------------------------------------------------------
# 7. 완료 안내
# -----------------------------------------------------------------
HARBOR_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "================================================================"
echo " Gitea 설치 완료"
echo "================================================================"
echo ""
echo " 접속 URL : https://${GITEA_DOMAIN} (DNS 등록 후)"
echo ""
echo " 관리자   : ${GITEA_ADMIN_USER} / ${GITEA_ADMIN_PASSWORD}"
echo ""
echo " 데이터   : ${GITEA_DATA_DIR}"
echo ""
echo " ※ 폐쇄망 이관 시:"
echo "   sudo docker save ${GITEA_IMAGE} | gzip > gitea-${GITEA_VERSION}.tar.gz"
echo "================================================================"
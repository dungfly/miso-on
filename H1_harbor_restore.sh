#!/bin/bash
# =================================================================
# H1_harbor_restore.sh - 폐쇄망 Harbor VM 복원 스크립트
#
# [실행 환경] 새 Harbor 서버 (폐쇄망)
#             miso-harbor-snapshot.tar.gz 가 ~/ 에 있어야 함
#
# [복원 대상]
#   - Harbor 컨테이너 이미지
#   - Harbor 데이터 (/data/harbor)
#   - Harbor 설치 디렉토리 (/opt/harbor)
#   - Harbor 인증서 (/etc/harbor/certs)
#   - deb repo / manifests / galaxy (/data)
#   - Gitea 이미지 + 데이터
#   - nginx apt-mirror + Gitea SSL 프록시
#
# [실행]
#   scp miso-harbor-snapshot.tar.gz ubuntu@<새Harbor IP>:~/
#   bash H1_harbor_restore.sh
# =================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SNAPSHOT_TGZ="${HOME}/miso-harbor-snapshot.tar.gz"
SNAPSHOT_DIR="${HOME}/miso-snapshot"
NEW_IP=$(hostname -I | awk '{print $1}')
HARBOR_INSTALL_DIR="/opt/harbor"
HARBOR_DATA_DIR="/data/harbor"
HARBOR_CERT_DIR="/etc/harbor/certs"

backup_external_apt_sources() {
  sudo mkdir -p /etc/apt/backup.miso
  if [ -f /etc/apt/sources.list ]; then
    sudo cp -a /etc/apt/sources.list /etc/apt/backup.miso/sources.list.bak 2>/dev/null || true
    sudo mv /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null || true
  fi
  sudo find /etc/apt/sources.list.d/ -maxdepth 1 -name "*.list" \
    ! -name "miso-*.list" -exec sudo mv {} {}.bak \; 2>/dev/null || true
}

register_local_repo() {
  local repo_name="$1"
  local repo_dir="$2"

  if [ ! -d "$repo_dir" ] || [ ! -f "${repo_dir}/Packages" ]; then
    echo "  ✗ ${repo_name} repo 없음: ${repo_dir}"
    exit 1
  fi

  echo "deb [trusted=yes] file://${repo_dir} ./" | sudo tee "/etc/apt/sources.list.d/miso-${repo_name}.list" >/dev/null
  echo "  ✓ 로컬 repo 등록: ${repo_name}"
}

require_repo_package() {
  local repo_dir="$1"
  local pkg="$2"
  if ! grep -q "^Package: ${pkg}$" "${repo_dir}/Packages"; then
    echo "  ✗ 필수 패키지 누락 (${repo_dir}): ${pkg}"
    exit 1
  fi
  echo "  ✓ 패키지 확인: ${pkg}"
}

ensure_image_tag() {
  local wanted_tag="$1"
  local loaded_ref
  loaded_ref=$(sudo docker images --format '{{.Repository}}:{{.Tag}}' | grep '^gitea/gitea:' | head -1 || true)
  if [ -z "$loaded_ref" ]; then
    echo "  ✗ 로드된 gitea 이미지 확인 실패"
    exit 1
  fi
  if [ "$loaded_ref" != "$wanted_tag" ]; then
    sudo docker tag "$loaded_ref" "$wanted_tag"
    echo "  ✓ Gitea 이미지 태그 보정: ${loaded_ref} -> ${wanted_tag}"
  else
    echo "  ✓ Gitea 이미지 태그 일치: ${wanted_tag}"
  fi
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " H1: 폐쇄망 Harbor VM 복원"
echo " 새 IP   : ${NEW_IP}"
echo " 입력    : ${SNAPSHOT_TGZ}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# -----------------------------------------------------------------
# STEP 0. 사전 확인
# -----------------------------------------------------------------
echo ""
echo ">>> [0] 사전 확인"

if [ ! -f "${SNAPSHOT_TGZ}" ]; then
  echo "  ✗ 스냅샷 파일 없음: ${SNAPSHOT_TGZ}"
  echo "  먼저 스냅샷 파일을 복사하세요:"
  echo "    scp miso-harbor-snapshot.tar.gz ubuntu@${NEW_IP}:~/"
  exit 1
fi
echo "  ✓ 스냅샷 파일 확인: $(du -sh "${SNAPSHOT_TGZ}" | cut -f1)"

AVAIL_GB=$(df -BG "${HOME}" | awk 'NR==2 {print $4}' | tr -d 'G')
if [ "${AVAIL_GB}" -lt 20 ]; then
  echo "  ✗ 디스크 여유 공간 부족: ${AVAIL_GB}GB (최소 20GB 필요)"
  exit 1
fi
echo "  ✓ 디스크 여유 공간: ${AVAIL_GB}GB"

# -----------------------------------------------------------------
# STEP 1. 스냅샷 압축 해제
# -----------------------------------------------------------------
echo ""
echo ">>> [1] 스냅샷 압축 해제"

rm -rf "${SNAPSHOT_DIR}"
tar -xzf "${SNAPSHOT_TGZ}" -C "${HOME}"
echo "  ✓ 압축 해제 완료"

if [ ! -f "${SNAPSHOT_DIR}/meta.env" ]; then
  echo "  ✗ meta.env 없음 - 스냅샷이 손상됐습니다"
  exit 1
fi

# shellcheck disable=SC1090
source "${SNAPSHOT_DIR}/meta.env"

echo "  스냅샷 정보:"
echo "    생성일시  : ${SNAPSHOT_DATE}"
echo "    원본 IP   : ${HARBOR_IP}"
echo "    도메인    : ${HARBOR_HOSTNAME}"
echo "    Harbor    : ${HARBOR_VERSION}"

# -----------------------------------------------------------------
# STEP 2. 기본 패키지 설치 (스냅샷 내 deb 사용)
# -----------------------------------------------------------------
echo ""
echo ">>> [2] 기본 패키지 설치"

echo "  외부 repo 비활성화..."
backup_external_apt_sources

TEMP_REPO_DIR="${SNAPSHOT_DIR}/data/debs/common"
DOCKER_DEB_DIR="${SNAPSHOT_DIR}/data/debs/docker"

require_repo_package "${TEMP_REPO_DIR}" ca-certificates
require_repo_package "${TEMP_REPO_DIR}" curl
require_repo_package "${TEMP_REPO_DIR}" gnupg
require_repo_package "${TEMP_REPO_DIR}" openssl
require_repo_package "${TEMP_REPO_DIR}" nginx
require_repo_package "${TEMP_REPO_DIR}" apt-utils
require_repo_package "${TEMP_REPO_DIR}" rsync
require_repo_package "${DOCKER_DEB_DIR}" docker-ce
require_repo_package "${DOCKER_DEB_DIR}" docker-ce-cli
require_repo_package "${DOCKER_DEB_DIR}" containerd.io
require_repo_package "${DOCKER_DEB_DIR}" docker-compose-plugin

register_local_repo "temp" "${TEMP_REPO_DIR}"
register_local_repo "docker" "${DOCKER_DEB_DIR}"
sudo apt-get update -qq

sudo apt-get install -y \
  ca-certificates curl gnupg openssl \
  nginx apt-utils rsync

echo "  ✓ 기본 패키지 설치 완료"

# -----------------------------------------------------------------
# STEP 3. Docker CE 설치 (스냅샷 내 docker deb 사용)
# -----------------------------------------------------------------
echo ""
echo ">>> [3] Docker CE 설치"

sudo apt-get update -qq
sudo apt-get install -y \
  docker-ce docker-ce-cli containerd.io docker-compose-plugin

sudo systemctl enable --now docker
sudo usermod -aG docker ubuntu || true
echo "  ✓ Docker 설치 완료"

# -----------------------------------------------------------------
# STEP 4. /data 디렉토리 복원
# -----------------------------------------------------------------
echo ""
echo ">>> [4] /data 디렉토리 복원"

sudo mkdir -p /data
sudo chown -R "$(id -u):$(id -g)" /data

echo "  debs 복원 중..."
rsync -a "${SNAPSHOT_DIR}/data/debs/" /data/debs/
echo "  ✓ debs: $(du -sh /data/debs | cut -f1)"

echo "  manifests 복원 중..."
rsync -a "${SNAPSHOT_DIR}/data/manifests/" /data/manifests/ 2>/dev/null || \
  mkdir -p /data/manifests
echo "  ✓ manifests 복원 완료"

echo "  galaxy 복원 중..."
rsync -a "${SNAPSHOT_DIR}/data/galaxy/" /data/galaxy/ 2>/dev/null || \
  mkdir -p /data/galaxy
echo "  ✓ galaxy 복원 완료"

# -----------------------------------------------------------------
# STEP 5. nginx apt-mirror 설정 + 기동
# -----------------------------------------------------------------
echo ""
echo ">>> [5] nginx apt-mirror 서빙 설정"

if [ -f "${SNAPSHOT_DIR}/nginx/sites-available/apt-mirror" ]; then
  sudo cp "${SNAPSHOT_DIR}/nginx/sites-available/apt-mirror" \
    /etc/nginx/sites-available/apt-mirror
else
  sudo tee /etc/nginx/sites-available/apt-mirror << 'NGINX'
server {
    listen 8080;
    server_name _;
    root /data;
    autoindex on;

    location /debs/      { autoindex on; }
    location /manifests/ { autoindex on; }
    location /galaxy/    { autoindex on; }
}
NGINX
fi

sudo ln -sf /etc/nginx/sites-available/apt-mirror \
  /etc/nginx/sites-enabled/apt-mirror
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl restart nginx
echo "  ✓ nginx apt-mirror 서빙 완료 (:8080)"

# -----------------------------------------------------------------
# STEP 6. Harbor 이미지 로드
# -----------------------------------------------------------------
echo ""
echo ">>> [6] Harbor 컨테이너 이미지 로드"

if [ -f "${SNAPSHOT_DIR}/docker/harbor-images.tar.gz" ]; then
  echo "  Harbor 이미지 로드 중 (시간이 걸립니다)..."
  sudo docker load < "${SNAPSHOT_DIR}/docker/harbor-images.tar.gz"
  echo "  ✓ Harbor 이미지 로드 완료"
else
  echo "  ✗ harbor-images.tar.gz 없음"
  exit 1
fi

# -----------------------------------------------------------------
# STEP 7. Harbor 데이터 복원
# -----------------------------------------------------------------
echo ""
echo ">>> [7] Harbor 데이터 복원"

sudo mkdir -p "${HARBOR_DATA_DIR}"
sudo mkdir -p "${HARBOR_DATA_DIR}"/{redis,registry,database,job_logs,trivy-adapter,secret}
sudo chown -R 999:999     "${HARBOR_DATA_DIR}/redis"
sudo chown -R 10000:10000 "${HARBOR_DATA_DIR}/registry"
sudo chmod 755 "${HARBOR_DATA_DIR}/redis" "${HARBOR_DATA_DIR}/registry"

echo "  Harbor 데이터 복원 중 (시간이 걸립니다)..."
sudo rsync -a "${SNAPSHOT_DIR}/data/harbor/" "${HARBOR_DATA_DIR}/"
echo "  ✓ Harbor 데이터 복원 완료: $(du -sh "${HARBOR_DATA_DIR}" | cut -f1)"

# -----------------------------------------------------------------
# STEP 8. Harbor 설치 파일 복원 + IP 업데이트
# -----------------------------------------------------------------
echo ""
echo ">>> [8] Harbor 설치 파일 복원"

sudo mkdir -p "${HARBOR_INSTALL_DIR}"
sudo cp -a "${SNAPSHOT_DIR}/harbor/." "${HARBOR_INSTALL_DIR}/"

if [ "${NEW_IP}" != "${HARBOR_IP}" ]; then
  echo "  IP 변경 감지: ${HARBOR_IP} → ${NEW_IP}"
  sudo sed -i "s|${HARBOR_IP}|${NEW_IP}|g" "${HARBOR_INSTALL_DIR}/harbor.yml"
  echo "  ✓ harbor.yml IP 업데이트"
fi

# Trivy 온라인 업데이트 차단
HARBOR_YML="${HARBOR_INSTALL_DIR}/harbor.yml"
if grep -q '^trivy:' "${HARBOR_YML}"; then
  if grep -q '^  skip_update:' "${HARBOR_YML}"; then
    sudo sed -i 's/^  skip_update:.*/  skip_update: true/' "${HARBOR_YML}"
    sudo sed -i 's/^  skip_java_db_update:.*/  skip_java_db_update: true/' "${HARBOR_YML}"
  else
    sudo awk '
      /^trivy:/ && !done {
        print;
        print "  skip_update: true";
        print "  skip_java_db_update: true";
        done=1; next
      }
      { print }
    ' "${HARBOR_YML}" | sudo tee "${HARBOR_YML}.tmp" >/dev/null
    sudo mv "${HARBOR_YML}.tmp" "${HARBOR_YML}"
  fi
  echo "  ✓ harbor.yml trivy offline 설정 반영"
fi

if ! grep -q "${HARBOR_HOSTNAME}" /etc/hosts; then
  echo "${NEW_IP} ${HARBOR_HOSTNAME}" | sudo tee -a /etc/hosts >/dev/null
fi
echo "  ✓ /etc/hosts 등록: ${NEW_IP} ${HARBOR_HOSTNAME}"

# -----------------------------------------------------------------
# STEP 9. 인증서 복원
# -----------------------------------------------------------------
echo ""
echo ">>> [9] 인증서 복원"

sudo mkdir -p "${HARBOR_CERT_DIR}"
sudo cp -a "${SNAPSHOT_DIR}/certs/." "${HARBOR_CERT_DIR}/"

if [ -f "${HARBOR_CERT_DIR}/ca.crt" ]; then
  sudo cp "${HARBOR_CERT_DIR}/ca.crt" \
    /usr/local/share/ca-certificates/miso-ca.crt
elif [ -f "${HARBOR_CERT_DIR}/harbor.crt" ]; then
  sudo cp "${HARBOR_CERT_DIR}/harbor.crt" \
    /usr/local/share/ca-certificates/miso-ca.crt
fi
sudo update-ca-certificates
echo "  ✓ 인증서 복원 완료"

# -----------------------------------------------------------------
# STEP 10. Harbor 기동
# -----------------------------------------------------------------
echo ""
echo ">>> [10] Harbor 기동"

sudo systemctl stop nginx

cd "${HARBOR_INSTALL_DIR}"
if [ -x ./prepare ]; then
  PREPARE_TAG="${HARBOR_VERSION_V:-v${HARBOR_VERSION}}"
  if sudo docker image inspect "goharbor/prepare:${PREPARE_TAG}" >/dev/null 2>&1; then
    sudo ./prepare --with-trivy
    echo "  ✓ prepare 완료"
  else
    echo "  ! goharbor/prepare:${PREPARE_TAG} 이미지 없음 - prepare 건너뜀 (기존 docker-compose.yml 사용)"
  fi
fi
# harbor-log(rsyslog :1514) 먼저 기동 후 나머지 컨테이너 연결
sudo docker compose up -d log
echo "  harbor-log 기동 대기 중 (최대 20초)..."
for i in $(seq 1 10); do
  if sudo docker exec harbor-log nc -z 127.0.0.1 1514 2>/dev/null; then
    echo "  ✓ harbor-log :1514 준비 완료"
    break
  fi
  sleep 2
done
sudo docker compose up -d
echo "  Harbor 기동 대기 중 (최대 5분)..."

HARBOR_READY=false
for i in $(seq 1 60); do
  HEALTH=$(curl -sk "https://${HARBOR_HOSTNAME}/api/v2.0/health" 2>/dev/null || true)
  if echo "${HEALTH}" | grep -q '"status": *"healthy"'; then
    echo "  ✓ Harbor 정상 기동 (${i}번째 시도)"
    HARBOR_READY=true
    break
  fi
  echo "  대기 중... (${i}/60)"
  sleep 5
done

if [ "${HARBOR_READY}" = "false" ]; then
  echo "  ✗ Harbor 기동 타임아웃"
  echo "  로그 확인: sudo docker compose -f ${HARBOR_INSTALL_DIR}/docker-compose.yml logs"
  exit 1
fi

# -----------------------------------------------------------------
# STEP 11. Gitea 복원 및 기동
# -----------------------------------------------------------------
echo ""
echo ">>> [11] Gitea 복원 및 기동"

if [ "${GITEA_RUNNING}" = "true" ] && \
   [ -f "${SNAPSHOT_DIR}/docker/gitea-image.tar.gz" ]; then

  echo "  Gitea 이미지 로드 중..."
  sudo docker load < "${SNAPSHOT_DIR}/docker/gitea-image.tar.gz"
  echo "  ✓ Gitea 이미지 로드 완료"

  sudo mkdir -p "${GITEA_DATA_DIR}"
  sudo chown -R 1000:1000 "${GITEA_DATA_DIR}"
  if [ -d "${SNAPSHOT_DIR}/data/gitea" ]; then
    sudo rsync -a "${SNAPSHOT_DIR}/data/gitea/" "${GITEA_DATA_DIR}/"
    sudo chown -R 1000:1000 "${GITEA_DATA_DIR}"
    echo "  ✓ Gitea 데이터 복원 완료"
  fi

  GITEA_IMAGE_TAG="gitea/gitea:${GITEA_VERSION}"
  ensure_image_tag "${GITEA_IMAGE_TAG}"

  sudo docker stop gitea 2>/dev/null || true
  sudo docker rm gitea 2>/dev/null || true
  sudo docker run -d \
    --name gitea \
    --restart unless-stopped \
    -e USER_UID=1000 \
    -e USER_GID=1000 \
    -e GITEA__server__DOMAIN="${HARBOR_HOSTNAME/harbor/gitea}" \
    -e GITEA__server__ROOT_URL="https://${HARBOR_HOSTNAME/harbor/gitea}" \
    -e GITEA__server__HTTP_PORT=3000 \
    -e GITEA__server__SSH_PORT=2222 \
    -e GITEA__server__SSH_LISTEN_PORT=2222 \
    -e GITEA__database__DB_TYPE=sqlite3 \
    -e GITEA__database__PATH=/data/gitea/gitea.db \
    -e GITEA__security__INSTALL_LOCK=true \
    -e GITEA__service__DISABLE_REGISTRATION=true \
    -v "${GITEA_DATA_DIR}:/data" \
    -p 3000:3000 \
    -p 2222:22 \
    "${GITEA_IMAGE_TAG}"
  echo "  ✓ Gitea 컨테이너 기동"
else
  echo "  Gitea 스냅샷 없음 - 건너뜀"
fi

# -----------------------------------------------------------------
# STEP 12. nginx Gitea SSL 프록시 설정 복원
# -----------------------------------------------------------------
echo ""
echo ">>> [12] nginx Gitea SSL 프록시 설정"

sudo mkdir -p /etc/nginx/certs
if [ -d "${SNAPSHOT_DIR}/nginx/certs" ]; then
  sudo cp -a "${SNAPSHOT_DIR}/nginx/certs/." /etc/nginx/certs/
fi

if [ -f "${SNAPSHOT_DIR}/nginx/sites-available/gitea" ]; then
  sudo cp "${SNAPSHOT_DIR}/nginx/sites-available/gitea" \
    /etc/nginx/sites-available/gitea
  sudo ln -sf /etc/nginx/sites-available/gitea \
    /etc/nginx/sites-enabled/gitea
fi

sudo nginx -t && sudo systemctl start nginx
echo "  ✓ nginx 재기동 완료 (:8080 apt-mirror, :8443 Gitea SSL)"

# -----------------------------------------------------------------
# STEP 13. Robot secret 복원
# -----------------------------------------------------------------
echo ""
echo ">>> [13] Robot secret 복원"

if [ -f "${SNAPSHOT_DIR}/harbor-robot-secret.txt" ]; then
  cp "${SNAPSHOT_DIR}/harbor-robot-secret.txt" "${HOME}/harbor-robot-secret.txt"
  chmod 600 "${HOME}/harbor-robot-secret.txt"
  echo "  ✓ harbor-robot-secret.txt 복원 완료"
  echo "  Robot: $(cut -d: -f1 < "${HOME}/harbor-robot-secret.txt")"
else
  echo "  ! harbor-robot-secret.txt 없음 - Robot account 재생성 필요"
  echo "  Harbor UI에서 수동으로 Robot account를 재생성하거나"
  echo "  H1_harbor_restore.sh 참고 STEP 5-b를 참고하세요"
fi

# -----------------------------------------------------------------
# STEP 14. 임시 파일 정리
# -----------------------------------------------------------------
echo ""
echo ">>> [14] 임시 파일 정리"
rm -rf "${SNAPSHOT_DIR}"
sudo rm -f /etc/apt/sources.list.d/miso-temp.list
sudo rm -f /etc/apt/sources.list.d/miso-docker.list
sudo apt-get update -qq 2>/dev/null || true
echo "  ✓ 정리 완료"

# -----------------------------------------------------------------
# 완료
# -----------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " H1 복원 완료"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " Harbor  : https://${HARBOR_HOSTNAME}"
echo " Admin   : admin / ${HARBOR_ADMIN_PASSWORD}"
echo " Gitea   : https://${HARBOR_HOSTNAME/harbor/gitea}"
echo " apt-mirror : http://${NEW_IP}:8080"
echo ""
if [ "${NEW_IP}" != "${HARBOR_IP}" ]; then
  echo " ⚠  IP가 변경되었습니다: ${HARBOR_IP} → ${NEW_IP}"
  echo "    hosts.ini 및 group_vars/all.yml의 harbor_ip를"
  echo "    ${NEW_IP} 로 업데이트하세요"
  echo ""
fi
echo " 다음 단계:"
echo "   Bastion에서 ansible-playbook -i hosts.ini A3_harbor_ca_distribute.yml"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
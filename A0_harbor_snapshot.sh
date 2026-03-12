#!/bin/bash
# =================================================================
# A0_harbor_snapshot.sh - Harbor VM 전체 스냅샷 패키징
#
# [실행 환경] 인터넷 환경의 Harbor 서버 (10.1.5.10)
#             A1 + A2 + A5 + A6 완료 후 실행
#
# [결과물]
#   ~/miso-harbor-snapshot.tar.gz
#     ├── snapshot/data/          ← /data 전체 (debs, manifests, harbor, gitea 등)
#     ├── snapshot/harbor/        ← /opt/harbor (harbor.yml, docker-compose.yml 등)
#     ├── snapshot/certs/         ← /etc/harbor/certs (인증서)
#     ├── snapshot/nginx/         ← /etc/nginx/sites-available (apt-mirror, gitea 설정)
#     ├── snapshot/docker/        ← Harbor docker images tar (harbor 컴포넌트)
#     └── snapshot/meta.env       ← 버전/IP/도메인 정보
#
# [실행]
#   bash A0_harbor_snapshot.sh
#
# [폐쇄망 복원]
#   scp miso-harbor-snapshot.tar.gz ubuntu@<새Harbor IP>:~/
#   bash H1_harbor_restore.sh
# =================================================================
set -euo pipefail

SNAPSHOT_DIR="${HOME}/miso-snapshot"
SNAPSHOT_TGZ="${HOME}/miso-harbor-snapshot.tar.gz"

HARBOR_INSTALL_DIR="/opt/harbor"
HARBOR_DATA_DIR="/data/harbor"
HARBOR_CERT_DIR="/etc/harbor/certs"
HARBOR_IP=$(hostname -I | awk '{print $1}')
HARBOR_HOSTNAME=$(grep -oP '(?<=hostname: ).*' /opt/harbor/harbor.yml 2>/dev/null || echo "harbor.miso.local")
# 실제 설치된 이미지에서 버전 추출 (harbor.yml _version은 installer 버전과 다를 수 있음)
HARBOR_VERSION_V=$(sudo docker images --format '{{.Tag}}' --filter 'reference=goharbor/harbor-core' \
  2>/dev/null | head -1 || echo "unknown")
# v prefix 없는 경우 대비
HARBOR_VERSION_V="v${HARBOR_VERSION_V#v}"
# harbor.yml용 버전 (v prefix 제거)
HARBOR_VERSION="${HARBOR_VERSION_V#v}"
GITEA_DATA_DIR="/data/gitea"
GITEA_VERSION=$(sudo docker inspect gitea --format '{{.Config.Image}}' 2>/dev/null | grep -oP '(?<=:).*' || echo "unknown")

require_path() {
  local path="$1"
  local msg="$2"
  if [ ! -e "$path" ]; then
    echo "  ✗ ${msg}: ${path}"
    exit 1
  fi
  echo "  ✓ ${msg}: ${path}"
}

check_repo_file() {
  local repo_dir="$1"
  local file_name="$2"
  local label="$3"
  if [ ! -f "${repo_dir}/${file_name}" ]; then
    echo "  ✗ ${label} 없음: ${repo_dir}/${file_name}"
    exit 1
  fi
  echo "  ✓ ${label}: ${repo_dir}/${file_name}"
}

check_repo_package() {
  local repo_dir="$1"
  local pkg="$2"
  local label="$3"
  if ! grep -q "^Package: ${pkg}$" "${repo_dir}/Packages"; then
    echo "  ✗ ${label} 패키지 누락: ${pkg}"
    exit 1
  fi
  echo "  ✓ ${label} 패키지 확인: ${pkg}"
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " A0: Harbor VM 스냅샷 패키징"
echo " Harbor  : ${HARBOR_HOSTNAME} (${HARBOR_IP})"
echo " Version : ${HARBOR_VERSION}"
echo " 출력    : ${SNAPSHOT_TGZ}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# -----------------------------------------------------------------
# 사전 확인
# -----------------------------------------------------------------
echo ""
echo ">>> [0] 사전 확인"

require_path "${HARBOR_INSTALL_DIR}/harbor.yml" "harbor.yml 확인"
require_path "${HARBOR_INSTALL_DIR}/docker-compose.yml" "docker-compose.yml 확인"
require_path "${HARBOR_DATA_DIR}" "/data/harbor 확인"
require_path "/data/debs" "/data/debs 확인"
require_path "/data/manifests" "/data/manifests 확인"
require_path "/data/galaxy" "/data/galaxy 확인"
require_path "/etc/nginx/sites-available" "nginx sites-available 확인"

# Harbor 실행 중 확인
if ! sudo docker ps | grep -q "goharbor"; then
  echo "  ✗ Harbor가 실행 중이 아닙니다. 먼저 Harbor를 기동하세요."
  exit 1
fi
echo "  ✓ Harbor 실행 중"

# Gitea 실행 중 확인
if ! sudo docker ps | grep -q "gitea"; then
  echo "  ! Gitea가 실행 중이 아닙니다. Gitea 데이터는 건너뜁니다."
  GITEA_RUNNING=false
else
  echo "  ✓ Gitea 실행 중"
  GITEA_RUNNING=true
fi

# 오프라인 복원 필수 repo 검증
check_repo_file "/data/debs/common" "Packages" "common repo Packages"
check_repo_file "/data/debs/docker" "Packages" "docker repo Packages"
check_repo_file "/data/debs/bastion" "Packages" "bastion repo Packages"
check_repo_file "/data/debs/monitor" "Packages" "monitor repo Packages"

check_repo_package "/data/debs/common" "ca-certificates" "common repo"
check_repo_package "/data/debs/common" "curl" "common repo"
check_repo_package "/data/debs/common" "gnupg" "common repo"
check_repo_package "/data/debs/common" "openssl" "common repo"
check_repo_package "/data/debs/common" "nginx" "common repo"
check_repo_package "/data/debs/common" "apt-utils" "common repo"
check_repo_package "/data/debs/common" "rsync" "common repo"
check_repo_package "/data/debs/docker" "docker-ce" "docker repo"
check_repo_package "/data/debs/docker" "docker-ce-cli" "docker repo"
check_repo_package "/data/debs/docker" "containerd.io" "docker repo"
check_repo_package "/data/debs/docker" "docker-compose-plugin" "docker repo"
check_repo_package "/data/debs/bastion" "ansible" "bastion repo"
check_repo_package "/data/debs/bastion" "kubectl" "bastion repo"
check_repo_package "/data/debs/monitor" "nginx-core" "monitor repo"

if [ -f "${HOME}/harbor-robot-secret.txt" ]; then
  echo "  ✓ harbor-robot-secret.txt 확인"
else
  echo "  ! harbor-robot-secret.txt 없음 - Robot secret는 스냅샷에 포함되지 않습니다"
fi

# 디스크 여유 공간 확인 (최소 10GB)
AVAIL_GB=$(df -BG "${HOME}" | awk 'NR==2 {print $4}' | tr -d 'G')
if [ "${AVAIL_GB}" -lt 10 ]; then
  echo "  ✗ 디스크 여유 공간 부족: ${AVAIL_GB}GB (최소 10GB 필요)"
  exit 1
fi
echo "  ✓ 디스크 여유 공간: ${AVAIL_GB}GB"

# 작업 디렉토리 초기화
sudo rm -rf "${SNAPSHOT_DIR}"
mkdir -p "${SNAPSHOT_DIR}"/{data,harbor,certs,nginx/dummy,docker}
rm -rf "${SNAPSHOT_DIR}/nginx/dummy"
mkdir -p "${SNAPSHOT_DIR}/nginx/sites-available" "${SNAPSHOT_DIR}/nginx/certs"

# -----------------------------------------------------------------
# STEP 1. Harbor 컨테이너 이미지 저장
# -----------------------------------------------------------------
echo ""
echo ">>> [1] Harbor 컨테이너 이미지 저장"

# Harbor docker-compose에서 사용하는 이미지 목록 추출
HARBOR_IMAGES=$(sudo docker compose -f "${HARBOR_INSTALL_DIR}/docker-compose.yml" \
  config --images 2>/dev/null || \
  sudo docker ps --filter "name=harbor" --format "{{.Image}}")

if [ -z "${HARBOR_IMAGES}" ]; then
  echo "  ✗ Harbor 이미지 목록 추출 실패"
  exit 1
fi

# prepare 이미지는 docker-compose 서비스가 아니라 별도 실행이므로 목록에 안 잡힘 → 명시적 추가
# harbor.yml 버전(v prefix 없을 수 있음)과 docker image 태그(v prefix 있음) 모두 시도
PREPARE_IMAGE=""
for VER in "${HARBOR_VERSION_V}" "${HARBOR_VERSION}"; do
  if sudo docker image inspect "goharbor/prepare:${VER}" >/dev/null 2>&1; then
    PREPARE_IMAGE="goharbor/prepare:${VER}"
    break
  fi
done

if [ -n "${PREPARE_IMAGE}" ]; then
  HARBOR_IMAGES="${HARBOR_IMAGES}
${PREPARE_IMAGE}"
  echo "  ✓ prepare 이미지 추가: ${PREPARE_IMAGE}"
else
  echo "  ! prepare 이미지 없음: goharbor/prepare:${HARBOR_VERSION_V} (harbor install 디렉토리에서 ./prepare 실행 후 재시도)"
  exit 1
fi

echo "  Harbor 이미지 목록:"
echo "${HARBOR_IMAGES}" | while read -r img; do
  [ -n "${img}" ] && echo "    - ${img}"
done

echo "  이미지 저장 중 (시간이 걸립니다)..."
# shellcheck disable=SC2086
sudo docker save ${HARBOR_IMAGES} | gzip > "${SNAPSHOT_DIR}/docker/harbor-images.tar.gz"
echo "  ✓ Harbor 이미지 저장 완료: $(du -sh "${SNAPSHOT_DIR}/docker/harbor-images.tar.gz" | cut -f1)"

# Gitea 이미지 저장
if [ "${GITEA_RUNNING}" = "true" ]; then
  GITEA_IMAGE=$(sudo docker inspect gitea --format '{{.Config.Image}}')
  echo "  Gitea 이미지 저장: ${GITEA_IMAGE}"
  sudo docker save "${GITEA_IMAGE}" | gzip > "${SNAPSHOT_DIR}/docker/gitea-image.tar.gz"
  echo "  ✓ Gitea 이미지 저장 완료"
fi

# -----------------------------------------------------------------
# STEP 2. Harbor 데이터 백업
# -----------------------------------------------------------------
echo ""
echo ">>> [2] Harbor 데이터 백업 (/data/harbor)"

# Harbor 일시 중지 (데이터 일관성)
echo "  Harbor 일시 중지..."
cd "${HARBOR_INSTALL_DIR}" && sudo docker compose stop
echo "  ✓ Harbor 중지"

echo "  Harbor 데이터 복사 중 (시간이 걸립니다)..."
sudo rsync -a --info=progress2 \
  "${HARBOR_DATA_DIR}/" \
  "${SNAPSHOT_DIR}/data/harbor/" 2>/dev/null || \
sudo cp -a "${HARBOR_DATA_DIR}/." "${SNAPSHOT_DIR}/data/harbor/"
echo "  ✓ Harbor 데이터 복사 완료: $(du -sh "${SNAPSHOT_DIR}/data/harbor" | cut -f1)"

# Harbor 재기동
echo "  Harbor 재기동..."
cd "${HARBOR_INSTALL_DIR}" && sudo docker compose start
echo "  ✓ Harbor 재기동"

# -----------------------------------------------------------------
# STEP 3. Harbor 설치 디렉토리 백업
# -----------------------------------------------------------------
echo ""
echo ">>> [3] Harbor 설치 파일 백업 (/opt/harbor)"

sudo cp -a "${HARBOR_INSTALL_DIR}/." "${SNAPSHOT_DIR}/harbor/"
echo "  ✓ Harbor 설치 파일 복사 완료"

# -----------------------------------------------------------------
# STEP 4. 인증서 백업
# -----------------------------------------------------------------
echo ""
echo ">>> [4] 인증서 백업"

sudo cp -a "${HARBOR_CERT_DIR}/." "${SNAPSHOT_DIR}/certs/"
echo "  ✓ 인증서 복사 완료"

# -----------------------------------------------------------------
# STEP 5. deb 패키지 / manifests / galaxy 백업
# -----------------------------------------------------------------
echo ""
echo ">>> [5] deb 패키지 / manifests / galaxy 백업"

echo "  /data/debs 복사 중..."
sudo rsync -a --info=progress2 /data/debs/ "${SNAPSHOT_DIR}/data/debs/" 2>/dev/null || \
  sudo cp -a /data/debs/. "${SNAPSHOT_DIR}/data/debs/"
echo "  ✓ debs: $(du -sh "${SNAPSHOT_DIR}/data/debs" | cut -f1)"

echo "  /data/manifests 복사 중..."
sudo cp -a /data/manifests/. "${SNAPSHOT_DIR}/data/manifests/" 2>/dev/null || true
echo "  ✓ manifests 복사 완료"

echo "  /data/galaxy 복사 중..."
sudo cp -a /data/galaxy/. "${SNAPSHOT_DIR}/data/galaxy/" 2>/dev/null || true
echo "  ✓ galaxy 복사 완료"

# Gitea 데이터
if [ "${GITEA_RUNNING}" = "true" ]; then
  echo "  Gitea 데이터 복사 중..."
  sudo docker stop gitea
  sudo cp -a "${GITEA_DATA_DIR}/." "${SNAPSHOT_DIR}/data/gitea/"
  sudo docker start gitea
  echo "  ✓ gitea: $(sudo du -sh "${SNAPSHOT_DIR}/data/gitea" | cut -f1)"
fi

# -----------------------------------------------------------------
# STEP 6. nginx 설정 백업
# -----------------------------------------------------------------
echo ""
echo ">>> [6] nginx 설정 백업"

sudo cp -a /etc/nginx/sites-available/. "${SNAPSHOT_DIR}/nginx/sites-available/"
sudo cp -a /etc/nginx/certs/. "${SNAPSHOT_DIR}/nginx/certs/" 2>/dev/null || true
echo "  ✓ nginx 설정 복사 완료"

# -----------------------------------------------------------------
# STEP 7. 메타 정보 저장
# -----------------------------------------------------------------
echo ""
echo ">>> [7] 메타 정보 저장"

HARBOR_ADMIN_PASSWORD=$(grep "harbor_admin_password" "${HARBOR_INSTALL_DIR}/harbor.yml" \
  | awk '{print $2}')
ROBOT_SECRET=""
if [ -f "${HOME}/harbor-robot-secret.txt" ]; then
  ROBOT_SECRET=$(cat "${HOME}/harbor-robot-secret.txt")
  cp "${HOME}/harbor-robot-secret.txt" "${SNAPSHOT_DIR}/harbor-robot-secret.txt"
fi

cat > "${SNAPSHOT_DIR}/meta.env" << EOF2
# A0_harbor_snapshot.sh 생성 정보
# 생성일시: $(date '+%Y-%m-%d %H:%M:%S')
SNAPSHOT_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
HARBOR_IP="${HARBOR_IP}"
HARBOR_HOSTNAME="${HARBOR_HOSTNAME}"
HARBOR_VERSION="${HARBOR_VERSION}"
HARBOR_VERSION_V="${HARBOR_VERSION_V}"
HARBOR_INSTALL_DIR="${HARBOR_INSTALL_DIR}"
HARBOR_DATA_DIR="${HARBOR_DATA_DIR}"
HARBOR_CERT_DIR="${HARBOR_CERT_DIR}"
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD}"
GITEA_VERSION="${GITEA_VERSION}"
GITEA_DATA_DIR="${GITEA_DATA_DIR}"
GITEA_RUNNING="${GITEA_RUNNING}"
EOF2

echo "  ✓ 메타 정보 저장 완료"

# -----------------------------------------------------------------
# STEP 8. tar.gz 패키징
# -----------------------------------------------------------------
echo ""
echo ">>> [8] tar.gz 패키징"
echo "  패키징 중 (시간이 걸립니다)..."

# snapshot 디렉토리 소유권 정리
# root 소유 파일(gitea/ssh 등)이 있으므로 sudo로 tar 패키징
sudo tar -czf "${SNAPSHOT_TGZ}" -C "${HOME}" "miso-snapshot"
sudo chown "$(id -u):$(id -g)" "${SNAPSHOT_TGZ}"
echo "  ✓ 패키징 완료: $(du -sh "${SNAPSHOT_TGZ}" | cut -f1)"

# 임시 디렉토리 정리
sudo rm -rf "${SNAPSHOT_DIR}"

# -----------------------------------------------------------------
# 완료
# -----------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " A0 완료"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 스냅샷 : ${SNAPSHOT_TGZ}"
echo " 다음 단계:"
echo "   폐쇄망 Harbor 서버로 복사 후 bash H1_harbor_restore.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
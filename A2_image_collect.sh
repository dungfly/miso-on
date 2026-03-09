#!/bin/bash
# =================================================================
# A2_image_collect.sh - 폐쇄망 대비 리소스 수집
#
# [실행 환경] Harbor 서버 (10.1.5.10) 에서 직접 실행
#             A1_harbor_install.sh 완료 상태 (nginx, docker 설치됨)
#
# [수집 내용]
#   1. 컨테이너 이미지  → Harbor push
#   2. deb 패키지       → /data/debs/{group}/ 저장
#   3. K8s manifest     → /data/manifests/ 저장
#   4. Ansible Galaxy   → /data/galaxy/ 저장
#
# 실행: bash A2_image_collect.sh
# =================================================================
# -e 제거: 일부 실패해도 끝까지 진행
set -uo pipefail

HARBOR_HOST="harbor.miso.local"
HARBOR_PROJECT="miso"
HARBOR_USER="admin"
HARBOR_PASSWORD="Harbor12345"

BASE_DIR="/data"
DEBS_BASE="${BASE_DIR}/debs"
MANIFESTS_DIR="${BASE_DIR}/manifests"
GALAXY_DIR="${BASE_DIR}/galaxy"

# =================================================================
# 0. 디렉토리 준비
# =================================================================
echo ">>> [0] 디렉토리 준비"
sudo mkdir -p \
  "${DEBS_BASE}/common" \
  "${DEBS_BASE}/k8s" \
  "${DEBS_BASE}/docker" \
  "${DEBS_BASE}/haproxy" \
  "${MANIFESTS_DIR}" \
  "${GALAXY_DIR}"
# 각 디렉토리만 개별 소유권 변경 (Harbor 데이터 절대 건드리지 않음)
# - /data/harbor/database → UID 999 (lxd/postgres)
# - /data/harbor/registry → UID 10000 (harbor)
# - /data 전체 chown 금지
for dir in "${DEBS_BASE}" "${MANIFESTS_DIR}" "${GALAXY_DIR}"; do
  sudo chown -R "$(id -u):$(id -g)" "${dir}"
  sudo chmod -R 755 "${dir}"
done

# Harbor registry storage 권한 보정 (harbor UID=10000)
# registry 컨테이너가 새 레포 디렉토리를 생성할 수 있어야 함
if [ -d "/data/harbor/registry" ]; then
  sudo chown -R 10000:10000 /data/harbor/registry
fi
# Harbor DB storage 권한 보정 (postgres UID=999)
if [ -d "/data/harbor/database" ]; then
  sudo chown -R 999:999 /data/harbor/database
  sudo chmod 700 /data/harbor/database/pg14 2>/dev/null || true
fi

# =================================================================
# 1. 컨테이너 이미지 수집
# =================================================================
echo ""
echo ">>> [1] 컨테이너 이미지 수집"

declare -A IMAGES=(
  ["minio"]="quay.io/minio/minio:latest"
  ["postgres"]="ghcr.io/cloudnative-pg/postgresql:16"
  ["cnpg"]="ghcr.io/cloudnative-pg/cloudnative-pg:1.22.1"
  ["redis"]="redis:7.4.3-alpine"
  ["opensearch"]="opensearchproject/opensearch:2.19.1"
  ["opensearch-dashboards"]="opensearchproject/opensearch-dashboards:2.19.1"
  ["busybox"]="busybox:1.36"
  ["prometheus"]="prom/prometheus:v2.51.0"
  ["grafana"]="grafana/grafana:10.4.2"
  ["alertmanager"]="prom/alertmanager:v0.27.0"
  ["loki"]="grafana/loki:2.9.8"
  ["promtail"]="grafana/promtail:2.9.8"
  ["node-exporter"]="prom/node-exporter:v1.7.0"
  ["argocd"]="quay.io/argoproj/argocd:v2.10.3"
  ["argocd-image-updater"]="quay.io/argoprojlabs/argocd-image-updater:v0.12.2"
  ["cert-manager-controller"]="quay.io/jetstack/cert-manager-controller:v1.14.4"
  ["cert-manager-webhook"]="quay.io/jetstack/cert-manager-webhook:v1.14.4"
  ["cert-manager-cainjector"]="quay.io/jetstack/cert-manager-cainjector:v1.14.4"
)

# 초기 로그인 확인
echo "${HARBOR_PASSWORD}" | sudo docker login "${HARBOR_HOST}" \
  -u "${HARBOR_USER}" --password-stdin

IMAGE_FAILED=()
for name in "${!IMAGES[@]}"; do
  src="${IMAGES[$name]}"
  tag="${src##*:}"
  dst="${HARBOR_HOST}/${HARBOR_PROJECT}/${name}:${tag}"
  echo "  [image] ${name}: ${src} → ${dst}"

  # 이미 Harbor에 있으면 skip
  if sudo docker manifest inspect "${dst}" > /dev/null 2>&1; then
    echo "    ✓ 이미 존재 (skip)"
    continue
  fi

  # push 직전 재로그인 (세션 만료 방지)
  echo "${HARBOR_PASSWORD}" | sudo docker login "${HARBOR_HOST}" \
    -u "${HARBOR_USER}" --password-stdin > /dev/null 2>&1

  if sudo docker pull "${src}" \
    && sudo docker tag "${src}" "${dst}" \
    && sudo docker push "${dst}"; then
    echo "    ✓ 완료"
  else
    echo "    ✗ 실패 (나중에 재시도 가능)"
    IMAGE_FAILED+=("${name}")
  fi
done

# =================================================================
# 2. deb 패키지 수집
# =================================================================
echo ""
echo ">>> [2] deb 패키지 수집"

# K8s 저장소 등록
echo "  K8s 저장소 등록..."
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

# Docker 저장소 등록 (이미 A1에서 등록됐지만 혹시 없을 경우 대비)
DOCKER_REPO_UPDATED=false
if [ ! -f /etc/apt/keyrings/docker.gpg ] || [ ! -f /etc/apt/sources.list.d/docker.list ]; then
  echo "  Docker 저장소 등록..."
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu jammy stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  DOCKER_REPO_UPDATED=true
fi

sudo apt-get update -qq

# Docker 저장소를 새로 등록한 경우 한 번 더 update (캐시 반영 보장)
if [ "${DOCKER_REPO_UPDATED}" = "true" ]; then
  echo "  Docker 저장소 재등록 후 추가 update..."
  sudo apt-get update -qq
fi

# 그룹별 패키지 다운로드 함수
download_pkgs() {
  local group=$1
  shift
  local dest="${DEBS_BASE}/${group}"
  local pkg_count
  pkg_count=$(ls "${dest}"/*.deb 2>/dev/null | wc -l)
  echo "  [deb/${group}] $* (현재 ${pkg_count}개)"

  # 이미 deb가 있고 Packages 인덱스도 있으면 skip
  if [ "${pkg_count}" -gt 0 ] && [ -s "${dest}/Packages" ]; then
    echo "    ✓ 이미 수집됨 (skip)"
    return 0
  fi

  # partial 디렉토리 생성 (apt 요구사항)
  sudo mkdir -p "${dest}/partial"

  sudo apt-get install --download-only --reinstall -y "$@" \
    -o Dir::Cache::archives="${dest}" \
    -o Dir::Cache::pkgcache="" \
    -o Dir::Cache::srcpkgcache="" \
    2>&1 | grep -E "^Get:|already|^\./" || true

  # lock/partial 정리
  sudo rm -f "${dest}/lock"
  sudo rm -rf "${dest}/partial"

  # Packages 인덱스 생성
  (cd "${dest}" && sudo apt-ftparchive packages . | sudo tee Packages > /dev/null)
  (cd "${dest}" && sudo gzip -k -f Packages)

  echo "    ✓ $(ls ${dest}/*.deb 2>/dev/null | wc -l)개 deb 수집"
}

download_pkgs "common" \
  curl jq git vim net-tools htop chrony iptables \
  ca-certificates gnupg openssl ansible nginx apt-utils

download_pkgs "k8s" \
  containerd kubelet kubeadm kubectl

download_pkgs "docker" \
  docker-ce docker-ce-cli containerd.io docker-compose-plugin

download_pkgs "haproxy" \
  haproxy

# =================================================================
# 3. K8s manifest 수집
# =================================================================
echo ""
echo ">>> [3] K8s manifest 수집"

declare -A MANIFESTS=(
  ["tigera-operator.yaml"]="https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml"
  ["calico-custom-resources.yaml"]="https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/custom-resources.yaml"
  ["ingress-nginx.yaml"]="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/baremetal/deploy.yaml"
  ["cert-manager.yaml"]="https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml"
  ["local-path-storage.yaml"]="https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml"
  ["argocd-install.yaml"]="https://raw.githubusercontent.com/argoproj/argo-cd/v2.10.3/manifests/install.yaml"
  ["argocd-image-updater.yaml"]="https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/config/install.yaml"
)

MANIFEST_FAILED=()
for fname in "${!MANIFESTS[@]}"; do
  url="${MANIFESTS[$fname]}"
  dest="${MANIFESTS_DIR}/${fname}"
  # 이미 수집됐으면 스킵
  if [ -f "${dest}" ] && [ -s "${dest}" ]; then
    echo "  [manifest] ${fname} ✓ (이미 존재 - skip)"
    continue
  fi
  echo "  [manifest] ${fname}"
  TMP_MANIFEST=$(mktemp)
  if curl -fsSL -L --retry 3 --retry-delay 5 "${url}" -o "${TMP_MANIFEST}" && [ -s "${TMP_MANIFEST}" ]; then
    sudo mv "${TMP_MANIFEST}" "${dest}"
    sudo chmod 644 "${dest}"
    echo "    ✓ $(wc -l < \"${dest}\") lines"
  else
    rm -f "${TMP_MANIFEST}"
    echo "    ✗ 실패 → ${url}"
    MANIFEST_FAILED+=("${fname}")
  fi
done

# cnpg manifest: 로컬 파일 우선, 없으면 온라인 다운로드
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CNPG_DEST="${MANIFESTS_DIR}/cnpg-1.22.1.yaml"
if [ -f "${CNPG_DEST}" ] && [ -s "${CNPG_DEST}" ]; then
  echo "  [manifest] cnpg-1.22.1.yaml ✓ (이미 존재 - skip)"
elif [ -f "${SCRIPT_DIR}/cnpg-1.22.1.yaml" ]; then
  sudo cp "${SCRIPT_DIR}/cnpg-1.22.1.yaml" "${CNPG_DEST}"
  echo "  [manifest] cnpg-1.22.1.yaml ✓ (로컬 복사)"
elif [ -f "${HOME}/cnpg-1.22.1.yaml" ]; then
  sudo cp "${HOME}/cnpg-1.22.1.yaml" "${CNPG_DEST}"
  echo "  [manifest] cnpg-1.22.1.yaml ✓ (홈디렉토리 복사)"
else
  echo "  [manifest] cnpg-1.22.1.yaml - 온라인 다운로드 시도..."
  CNPG_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.22/releases/cnpg-1.22.1.yaml"
  TMP_CNPG=$(mktemp)
  if curl -fsSL -L --retry 3 --retry-delay 5 "${CNPG_URL}" -o "${TMP_CNPG}" && [ -s "${TMP_CNPG}" ]; then
    sudo mv "${TMP_CNPG}" "${CNPG_DEST}"
    sudo chmod 644 "${CNPG_DEST}"
    echo "    ✓ 온라인 다운로드 완료"
  else
    rm -f "${TMP_CNPG}"
    echo "    ✗ 다운로드 실패 - 수동으로 ${CNPG_DEST} 에 복사 필요"
    MANIFEST_FAILED+=("cnpg-1.22.1.yaml")
  fi
fi

# =================================================================
# 4. nginx 서빙 설정 확인 및 reload
# =================================================================
echo ""
echo ">>> [4] nginx 서빙 설정 확인"

# A1에서 설정됐어야 하지만, 혹시 없으면 재설정
if [ ! -f /etc/nginx/sites-available/apt-mirror ]; then
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
  sudo ln -sf /etc/nginx/sites-available/apt-mirror \
              /etc/nginx/sites-enabled/apt-mirror
  sudo rm -f /etc/nginx/sites-enabled/default
fi

sudo nginx -t && sudo systemctl reload nginx

# 서빙 확인
HARBOR_IP=$(hostname -I | awk '{print $1}')
echo "  ✓ http://${HARBOR_IP}:8080/debs/"
echo "  ✓ http://${HARBOR_IP}:8080/manifests/"
echo "  ✓ http://${HARBOR_IP}:8080/galaxy/"

# 접근 테스트
for path in "debs/common/Packages" "manifests/tigera-operator.yaml"; do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://${HARBOR_IP}:8080/${path}" 2>/dev/null || echo "000")
  if [ "${HTTP}" = "200" ]; then
    echo "  ✓ http://${HARBOR_IP}:8080/${path} → ${HTTP}"
  else
    echo "  ✗ http://${HARBOR_IP}:8080/${path} → ${HTTP} (확인 필요)"
  fi
done

# =================================================================
# 5. Ansible Galaxy 컬렉션 수집
# =================================================================
echo ""
echo ">>> [5] Ansible Galaxy 컬렉션 수집"

if ! command -v ansible-galaxy &>/dev/null; then
  echo "  ansible-galaxy 없음 → 설치 중"
  sudo apt-get install -y ansible -qq
fi

# /data는 sudo로 만들어서 현재 유저 권한 없음 → 임시 디렉토리에 받은 후 이동
GALAXY_TMP=$(mktemp -d)
ansible-galaxy collection download \
  community.docker \
  community.general \
  ansible.posix \
  -p "${GALAXY_TMP}" 2>&1 | grep -v "^Process\|^Downloading" || true

# 결과물을 GALAXY_DIR로 이동
sudo mv "${GALAXY_TMP}"/*.tar.gz "${GALAXY_DIR}/" 2>/dev/null || true
sudo chmod 644 "${GALAXY_DIR}"/*.tar.gz 2>/dev/null || true
rm -rf "${GALAXY_TMP}"

GALAXY_COUNT=$(ls "${GALAXY_DIR}"/*.tar.gz 2>/dev/null | wc -l)
echo "  ✓ ${GALAXY_COUNT}개 컬렉션 수집 완료"

# =================================================================
# 완료 요약
# =================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " A2 수집 완료"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[ ${#IMAGE_FAILED[@]}    -gt 0 ] && echo " ✗ 이미지 실패    : ${IMAGE_FAILED[*]}"
[ ${#MANIFEST_FAILED[@]} -gt 0 ] && echo " ✗ manifest 실패  : ${MANIFEST_FAILED[*]}"
[ ${#IMAGE_FAILED[@]}    -eq 0 ] && [ ${#MANIFEST_FAILED[@]} -eq 0 ] && echo " ✓ 모든 항목 수집 완료"

echo ""
echo " [서빙 주소]"
echo "   이미지   : https://harbor.miso.local"
echo "   패키지   : http://${HARBOR_IP}:8080/debs/{common|k8s|docker|haproxy}"
echo "   manifest : http://${HARBOR_IP}:8080/manifests/{파일명}"
echo "   galaxy   : http://${HARBOR_IP}:8080/galaxy/"
echo ""
echo " 다음 단계:"
echo "   베스천에서: ansible-playbook -i hosts.ini A4_local_repo_setup.yml"
echo "   [K8s 구성 완료 후]: ansible-playbook -i hosts.ini A3_harbor_ca_distribute.yml"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
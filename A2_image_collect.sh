#!/bin/bash
# =================================================================
# A2_image_collect_reinforced.sh - 폐쇄망 대비 리소스 수집 (보강판)
#
# [실행 환경] Harbor 서버에서 직접 실행
#             A1_harbor_install.sh 완료 상태
#
# [주요 보강]
#   - kubeadm v1.30.14 기준 pause:3.10.1 추가 수집
#   - 기존 호환용 pause:3.9도 함께 유지
#   - push 후 Harbor manifest inspect로 검증
#   - 필수 K8s 이미지 존재 여부 최종 검증
#
# [실행]
#   bash A2_image_collect_reinforced.sh
# =================================================================
set -uo pipefail

HARBOR_HOST="${HARBOR_HOST:-harbor.miso.local}"
HARBOR_PROJECT="${HARBOR_PROJECT:-miso}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASSWORD="${HARBOR_PASSWORD:-Harbor12345}"

BASE_DIR="/data"
DEBS_BASE="${BASE_DIR}/debs"
MANIFESTS_DIR="${BASE_DIR}/manifests"
GALAXY_DIR="${BASE_DIR}/galaxy"

K8S_VERSION="v1.30.14"
K8S_DEB_VERSION="1.30.14-1.1"
CONTAINERD_DEB_VERSION="2.2.1-1~ubuntu.22.04~jammy"
DOCKER_CE_DEB_VERSION="5:29.3.0-1~ubuntu.22.04~jammy"

log() {
  echo "[A2] $*"
}

ensure_dirs() {
  log "디렉토리 준비"
  sudo mkdir -p \
    "${DEBS_BASE}/common" \
    "${DEBS_BASE}/k8s" \
    "${DEBS_BASE}/docker" \
    "${DEBS_BASE}/haproxy" \
    "${MANIFESTS_DIR}" \
    "${GALAXY_DIR}"

  for dir in "${DEBS_BASE}" "${MANIFESTS_DIR}" "${GALAXY_DIR}"; do
    sudo chown -R "$(id -u):$(id -g)" "${dir}"
    sudo chmod -R 755 "${dir}"
  done

  if [ -d "/data/harbor/registry" ]; then
    sudo chown -R 10000:10000 /data/harbor/registry
  fi
  if [ -d "/data/harbor/database" ]; then
    sudo chown -R 999:999 /data/harbor/database
    sudo chmod 700 /data/harbor/database/pg14 2>/dev/null || true
  fi
}

docker_login() {
  echo "${HARBOR_PASSWORD}" | sudo docker login "${HARBOR_HOST}" \
    -u "${HARBOR_USER}" --password-stdin >/dev/null
}

push_image() {
  local logical_name="$1"
  local src="$2"
  local dst_repo="$3"
  local dst_tag="$4"
  local dst="${HARBOR_HOST}/${HARBOR_PROJECT}/${dst_repo}:${dst_tag}"

  echo "  [image] ${logical_name}: ${src} -> ${dst}"

  if sudo docker manifest inspect "${dst}" >/dev/null 2>&1; then
    echo "    ✓ 이미 존재 (skip)"
    return 0
  fi

  docker_login

  if sudo docker pull "${src}" \
    && sudo docker tag "${src}" "${dst}" \
    && sudo docker push "${dst}" \
    && sudo docker manifest inspect "${dst}" >/dev/null 2>&1; then
    echo "    ✓ 완료"
    return 0
  fi

  echo "    ✗ 실패"
  return 1
}

download_pkgs() {
  local group=$1
  shift
  local dest="${DEBS_BASE}/${group}"
  local pkg_count
  pkg_count=$(find "${dest}" -maxdepth 1 -name "*.deb" 2>/dev/null | wc -l)
  echo "  [deb/${group}] $* (현재 ${pkg_count}개)"

  if [ "${pkg_count}" -gt 0 ] && [ -s "${dest}/Packages" ]; then
    echo "    ✓ 이미 수집됨 (skip)"
    return 0
  fi

  sudo mkdir -p "${dest}/partial"

  sudo apt-get install --download-only --reinstall -y "$@" \
    -o Dir::Cache::archives="${dest}" \
    -o Dir::Cache::pkgcache="" \
    -o Dir::Cache::srcpkgcache="" \
    2>&1 | grep -E "^Get:|already|^\./" || true

  sudo rm -f "${dest}/lock"
  sudo rm -rf "${dest}/partial"

  (cd "${dest}" && sudo apt-ftparchive packages . | sudo tee Packages >/dev/null)
  (cd "${dest}" && sudo gzip -k -f Packages)

  echo "    ✓ $(find "${dest}" -maxdepth 1 -name "*.deb" 2>/dev/null | wc -l)개 deb 수집"
}

# =================================================================
# 0. 준비
# =================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " A2 보강판: 이미지 / deb / manifest / galaxy 수집"
echo " Harbor   : ${HARBOR_HOST}/${HARBOR_PROJECT}"
echo " K8s      : ${K8S_VERSION}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ensure_dirs

# =================================================================
# 1. 컨테이너 이미지 수집
# =================================================================
echo ""
echo ">>> [1] 컨테이너 이미지 수집"

IMAGE_FAILED=()

# Harbor 로그인 확인
if ! docker_login; then
  echo "  ✗ Harbor 로그인 실패"
  exit 1
fi

# K8s 시스템 이미지
push_image "kube-apiserver"           "registry.k8s.io/kube-apiserver:${K8S_VERSION}"           "kube-apiserver"           "${K8S_VERSION}" || IMAGE_FAILED+=("kube-apiserver")
push_image "kube-controller-manager"  "registry.k8s.io/kube-controller-manager:${K8S_VERSION}"  "kube-controller-manager"  "${K8S_VERSION}" || IMAGE_FAILED+=("kube-controller-manager")
push_image "kube-scheduler"           "registry.k8s.io/kube-scheduler:${K8S_VERSION}"           "kube-scheduler"           "${K8S_VERSION}" || IMAGE_FAILED+=("kube-scheduler")
push_image "kube-proxy"               "registry.k8s.io/kube-proxy:${K8S_VERSION}"               "kube-proxy"               "${K8S_VERSION}" || IMAGE_FAILED+=("kube-proxy")
push_image "pause-3.9"                "registry.k8s.io/pause:3.9"                               "pause"                    "3.9" || IMAGE_FAILED+=("pause:3.9")
push_image "pause-3.10.1"             "registry.k8s.io/pause:3.10.1"                            "pause"                    "3.10.1" || IMAGE_FAILED+=("pause:3.10.1")
push_image "etcd"                     "registry.k8s.io/etcd:3.5.15-0"                           "etcd"                     "3.5.15-0" || IMAGE_FAILED+=("etcd")
push_image "coredns"                  "registry.k8s.io/coredns/coredns:v1.11.3"                 "coredns"                  "v1.11.3" || IMAGE_FAILED+=("coredns")

# Calico / CNI
push_image "tigera-operator"          "quay.io/tigera/operator:v1.32.3"                         "tigera-operator"          "v1.32.3" || IMAGE_FAILED+=("tigera-operator")
push_image "calico-node"              "docker.io/calico/node:v3.27.0"                           "calico-node"              "v3.27.0" || IMAGE_FAILED+=("calico-node")
push_image "calico-cni"               "docker.io/calico/cni:v3.27.0"                            "calico-cni"               "v3.27.0" || IMAGE_FAILED+=("calico-cni")
push_image "calico-kube-controllers"  "docker.io/calico/kube-controllers:v3.27.0"               "calico-kube-controllers"  "v3.27.0" || IMAGE_FAILED+=("calico-kube-controllers")
push_image "calico-typha"             "docker.io/calico/typha:v3.27.0"                          "calico-typha"             "v3.27.0" || IMAGE_FAILED+=("calico-typha")
push_image "calico-apiserver"         "docker.io/calico/apiserver:v3.27.0"                      "calico-apiserver"         "v3.27.0" || IMAGE_FAILED+=("calico-apiserver")
push_image "calico-csi"               "docker.io/calico/csi:v3.27.0"                            "calico-csi"               "v3.27.0" || IMAGE_FAILED+=("calico-csi")
push_image "calico-node-driver-registrar" "docker.io/calico/node-driver-registrar:v3.27.0"     "calico-node-driver-registrar" "v3.27.0" || IMAGE_FAILED+=("calico-node-driver-registrar")
push_image "calico-pod2daemon-flexvol" "docker.io/calico/pod2daemon-flexvol:v3.27.0"            "calico-pod2daemon-flexvol" "v3.27.0" || IMAGE_FAILED+=("calico-pod2daemon-flexvol")
push_image "calico-dikastes"          "docker.io/calico/dikastes:v3.27.0"                       "calico-dikastes"          "v3.27.0" || IMAGE_FAILED+=("calico-dikastes")

# ingress-nginx / storage
push_image "ingress-nginx-controller" "registry.k8s.io/ingress-nginx/controller:v1.10.1"        "ingress-nginx-controller" "v1.10.1" || IMAGE_FAILED+=("ingress-nginx-controller")
push_image "ingress-nginx-kube-webhook-certgen" "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.4.1" "ingress-nginx-kube-webhook-certgen" "v1.4.1" || IMAGE_FAILED+=("ingress-nginx-kube-webhook-certgen")
push_image "local-path-provisioner"   "docker.io/rancher/local-path-provisioner:v0.0.30"        "local-path-provisioner"   "v0.0.30" || IMAGE_FAILED+=("local-path-provisioner")

# 앱 이미지
push_image "minio"                    "quay.io/minio/minio:RELEASE.2024-11-07T00-52-20Z"        "minio"                    "RELEASE.2024-11-07T00-52-20Z" || IMAGE_FAILED+=("minio")
push_image "postgres"                 "ghcr.io/cloudnative-pg/postgresql:16"                    "postgres"                 "16" || IMAGE_FAILED+=("postgres")
push_image "cnpg"                     "ghcr.io/cloudnative-pg/cloudnative-pg:1.22.1"            "cnpg"                     "1.22.1" || IMAGE_FAILED+=("cnpg")
push_image "redis"                    "docker.io/redis:7.4.3-alpine"                             "redis"                    "7.4.3-alpine" || IMAGE_FAILED+=("redis")
push_image "opensearch"               "docker.io/opensearchproject/opensearch:2.19.1"           "opensearch"               "2.19.1" || IMAGE_FAILED+=("opensearch")
push_image "opensearch-dashboards"    "docker.io/opensearchproject/opensearch-dashboards:2.19.1" "opensearch-dashboards"  "2.19.1" || IMAGE_FAILED+=("opensearch-dashboards")
push_image "busybox"                  "docker.io/busybox:1.36"                                   "busybox"                  "1.36" || IMAGE_FAILED+=("busybox")
push_image "prometheus"               "docker.io/prom/prometheus:v2.51.0"                        "prometheus"               "v2.51.0" || IMAGE_FAILED+=("prometheus")
push_image "grafana"                  "docker.io/grafana/grafana:10.4.2"                         "grafana"                  "10.4.2" || IMAGE_FAILED+=("grafana")
push_image "alertmanager"             "docker.io/prom/alertmanager:v0.27.0"                      "alertmanager"             "v0.27.0" || IMAGE_FAILED+=("alertmanager")
push_image "loki"                     "docker.io/grafana/loki:2.9.8"                             "loki"                     "2.9.8" || IMAGE_FAILED+=("loki")
push_image "promtail"                 "docker.io/grafana/promtail:2.9.8"                         "promtail"                 "2.9.8" || IMAGE_FAILED+=("promtail")
push_image "node-exporter"            "docker.io/prom/node-exporter:v1.7.0"                      "node-exporter"            "v1.7.0" || IMAGE_FAILED+=("node-exporter")
push_image "argocd"                   "quay.io/argoproj/argocd:v2.10.3"                          "argocd"                   "v2.10.3" || IMAGE_FAILED+=("argocd")
push_image "argocd-dex"               "ghcr.io/dexidp/dex:v2.37.0"                               "argocd-dex"               "v2.37.0" || IMAGE_FAILED+=("argocd-dex")
push_image "argocd-redis"             "docker.io/redis:7.0.14-alpine"                             "argocd-redis"             "7.0.14-alpine" || IMAGE_FAILED+=("argocd-redis")
push_image "argocd-image-updater"     "quay.io/argoprojlabs/argocd-image-updater:v1.1.1"        "argocd-image-updater"     "v1.1.1" || IMAGE_FAILED+=("argocd-image-updater")
push_image "cert-manager-controller"  "quay.io/jetstack/cert-manager-controller:v1.14.4"        "cert-manager-controller"  "v1.14.4" || IMAGE_FAILED+=("cert-manager-controller")
push_image "cert-manager-webhook"     "quay.io/jetstack/cert-manager-webhook:v1.14.4"           "cert-manager-webhook"     "v1.14.4" || IMAGE_FAILED+=("cert-manager-webhook")
push_image "cert-manager-cainjector"  "quay.io/jetstack/cert-manager-cainjector:v1.14.4"        "cert-manager-cainjector"  "v1.14.4" || IMAGE_FAILED+=("cert-manager-cainjector")
push_image "gitea"                    "docker.io/gitea/gitea:1.25.4"                             "gitea"                    "1.25.4" || IMAGE_FAILED+=("gitea")
push_image "postgres-exporter"        "quay.io/prometheuscommunity/postgres-exporter:v0.15.0"   "postgres-exporter"        "v0.15.0" || IMAGE_FAILED+=("postgres-exporter")
push_image "redis-exporter"           "docker.io/oliver006/redis_exporter:v1.58.0"              "redis-exporter"           "v1.58.0" || IMAGE_FAILED+=("redis-exporter")
push_image "opensearch-exporter"      "quay.io/prometheuscommunity/elasticsearch-exporter:v1.7.0" "opensearch-exporter"    "v1.7.0" || IMAGE_FAILED+=("opensearch-exporter")

echo ">>> busybox:1.36 -> busybox:latest 추가 태깅"
sudo docker tag "${HARBOR_HOST}/${HARBOR_PROJECT}/busybox:1.36" \
                "${HARBOR_HOST}/${HARBOR_PROJECT}/busybox:latest" 2>/dev/null \
  && sudo docker push "${HARBOR_HOST}/${HARBOR_PROJECT}/busybox:latest" >/dev/null 2>&1 \
  && echo "  ✓ busybox:latest 완료" \
  || echo "  ! busybox:latest 실패 (1.36은 유지됨)"

echo ""
echo ">>> [1-b] 필수 K8s 이미지 존재 검증"
REQUIRED_K8S_IMAGES=(
  "kube-apiserver:${K8S_VERSION}"
  "kube-controller-manager:${K8S_VERSION}"
  "kube-scheduler:${K8S_VERSION}"
  "kube-proxy:${K8S_VERSION}"
  "pause:3.10.1"
  "pause:3.9"
  "etcd:3.5.15-0"
  "coredns:v1.11.3"
)

VERIFY_FAILED=()
for item in "${REQUIRED_K8S_IMAGES[@]}"; do
  repo="${item%%:*}"
  tag="${item#*:}"
  dst="${HARBOR_HOST}/${HARBOR_PROJECT}/${repo}:${tag}"
  if sudo docker manifest inspect "${dst}" >/dev/null 2>&1; then
    echo "  ✓ ${dst}"
  else
    echo "  ✗ ${dst}"
    VERIFY_FAILED+=("${dst}")
  fi
done

# =================================================================
# 2. deb 패키지 수집
# =================================================================
echo ""
echo ">>> [2] deb 패키지 수집"

echo "  K8s 저장소 등록..."
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

DOCKER_REPO_UPDATED=false
if [ ! -f /etc/apt/keyrings/docker.gpg ] || [ ! -f /etc/apt/sources.list.d/docker.list ]; then
  echo "  Docker 저장소 등록..."
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu jammy stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  DOCKER_REPO_UPDATED=true
fi

sudo apt-get update -qq
if [ "${DOCKER_REPO_UPDATED}" = "true" ]; then
  sudo apt-get update -qq
fi

download_pkgs "common" \
  curl jq git vim net-tools htop chrony iptables \
  ca-certificates gnupg openssl ansible nginx apt-utils

download_pkgs "k8s" \
  "kubelet=${K8S_DEB_VERSION}" \
  "kubeadm=${K8S_DEB_VERSION}" \
  "kubectl=${K8S_DEB_VERSION}"

download_pkgs "docker" \
  "docker-ce=${DOCKER_CE_DEB_VERSION}" \
  "docker-ce-cli=${DOCKER_CE_DEB_VERSION}" \
  "containerd.io=${CONTAINERD_DEB_VERSION}" \
  docker-compose-plugin

download_pkgs "haproxy" haproxy

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
  ["argocd-image-updater.yaml"]="https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/v1.1.1/config/install.yaml"
)

MANIFEST_FAILED=()
for fname in "${!MANIFESTS[@]}"; do
  url="${MANIFESTS[$fname]}"
  dest="${MANIFESTS_DIR}/${fname}"

  if [ -f "${dest}" ] && [ -s "${dest}" ]; then
    echo "  [manifest] ${fname} ✓ (이미 존재 - skip)"
    continue
  fi

  echo "  [manifest] ${fname}"
  tmp=$(mktemp)
  if curl -fsSL -L --retry 3 --retry-delay 5 "${url}" -o "${tmp}" && [ -s "${tmp}" ]; then
    sudo mv "${tmp}" "${dest}"
    sudo chmod 644 "${dest}"
    echo "    ✓ $(wc -l < "${dest}") lines"
  else
    rm -f "${tmp}"
    echo "    ✗ 실패 -> ${url}"
    MANIFEST_FAILED+=("${fname}")
  fi
done

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
  tmp=$(mktemp)
  if curl -fsSL -L --retry 3 --retry-delay 5 "${CNPG_URL}" -o "${tmp}" && [ -s "${tmp}" ]; then
    sudo mv "${tmp}" "${CNPG_DEST}"
    sudo chmod 644 "${CNPG_DEST}"
    echo "    ✓ 온라인 다운로드 완료"
  else
    rm -f "${tmp}"
    echo "    ✗ 다운로드 실패 - 수동으로 ${CNPG_DEST} 에 복사 필요"
    MANIFEST_FAILED+=("cnpg-1.22.1.yaml")
  fi
fi

# =================================================================
# 4. nginx 서빙 설정 확인 및 reload
# =================================================================
echo ""
echo ">>> [4] nginx 서빙 설정 확인"

if [ ! -f /etc/nginx/sites-available/apt-mirror ]; then
  sudo tee /etc/nginx/sites-available/apt-mirror >/dev/null << 'NGINX'
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
  sudo ln -sf /etc/nginx/sites-available/apt-mirror /etc/nginx/sites-enabled/apt-mirror
  sudo rm -f /etc/nginx/sites-enabled/default
fi

sudo nginx -t && sudo systemctl reload nginx

HARBOR_IP=$(hostname -I | awk '{print $1}')
for path in "debs/common/Packages" "manifests/tigera-operator.yaml"; do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://${HARBOR_IP}:8080/${path}" 2>/dev/null || echo "000")
  if [ "${HTTP}" = "200" ]; then
    echo "  ✓ http://${HARBOR_IP}:8080/${path} -> ${HTTP}"
  else
    echo "  ✗ http://${HARBOR_IP}:8080/${path} -> ${HTTP}"
  fi
done

# =================================================================
# 5. Ansible Galaxy 컬렉션 수집
# =================================================================
echo ""
echo ">>> [5] Ansible Galaxy 컬렉션 수집"

if ! command -v ansible-galaxy >/dev/null 2>&1; then
  echo "  ansible-galaxy 없음 -> 설치 중"
  sudo apt-get install -y ansible -qq
fi

GALAXY_TMP=$(mktemp -d)
ansible-galaxy collection download \
  community.docker \
  community.general \
  ansible.posix \
  -p "${GALAXY_TMP}" 2>&1 | grep -v "^Process\|^Downloading" || true

sudo mv "${GALAXY_TMP}"/*.tar.gz "${GALAXY_DIR}/" 2>/dev/null || true
sudo chmod 644 "${GALAXY_DIR}"/*.tar.gz 2>/dev/null || true
rm -rf "${GALAXY_TMP}"

GALAXY_COUNT=$(find "${GALAXY_DIR}" -maxdepth 1 -name "*.tar.gz" 2>/dev/null | wc -l)
echo "  ✓ ${GALAXY_COUNT}개 컬렉션 수집 완료"

# =================================================================
# 완료 요약
# =================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " A2 보강판 완료"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[ ${#IMAGE_FAILED[@]} -gt 0 ] && echo " ✗ 이미지 수집 실패 : ${IMAGE_FAILED[*]}"
[ ${#VERIFY_FAILED[@]} -gt 0 ] && echo " ✗ 필수 이미지 누락 : ${VERIFY_FAILED[*]}"
[ ${#MANIFEST_FAILED[@]} -gt 0 ] && echo " ✗ manifest 실패   : ${MANIFEST_FAILED[*]}"

if [ ${#IMAGE_FAILED[@]} -eq 0 ] && [ ${#VERIFY_FAILED[@]} -eq 0 ] && [ ${#MANIFEST_FAILED[@]} -eq 0 ]; then
  echo " ✓ 모든 항목 수집 완료"
fi

echo ""
echo " [서빙 주소]"
echo "   이미지   : https://${HARBOR_HOST}"
echo "   패키지   : http://${HARBOR_IP}:8080/debs/{common|k8s|docker|haproxy}"
echo "   manifest : http://${HARBOR_IP}:8080/manifests/{파일명}"
echo "   galaxy   : http://${HARBOR_IP}:8080/galaxy/"
echo ""
echo " 다음 단계:"
echo "   1) bash A5_bastion_pkg_collect.sh"
echo "   2) bash A6_gitea_install.sh"
echo "   3) bash A0_harbor_snapshot.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
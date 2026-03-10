#!/bin/bash
# =================================================================
# A5_bastion_pkg_collect.sh - Bastion 전용 패키지 수집
#
# [실행 환경] Harbor 서버 (10.1.5.10) 에서 실행
#             A1, A2 완료 후 실행
#
# [결과물] /data/debs/bastion/ → nginx :8080 으로 서빙
#          Bastion이 http://10.1.5.10:8080/debs/bastion/ 에서 설치
#
# 실행: bash A5_bastion_pkg_collect.sh
# =================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

BASTION_DEBS_DIR="/data/debs/bastion"
GALAXY_DIR="/data/galaxy"
K8S_VERSION="1.30"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " A5: Bastion 전용 패키지 수집 (Harbor 서버에서 실행)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

sudo mkdir -p "${BASTION_DEBS_DIR}/partial" "${GALAXY_DIR}"
sudo chown -R "$(id -u):$(id -g)" "${BASTION_DEBS_DIR}" "${GALAXY_DIR}"

# =================================================================
# STEP 1. K8s 저장소 등록 (kubectl 수집용)
# =================================================================
echo ""
echo ">>> [1] K8s 저장소 등록"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
sudo apt-get update -qq

# =================================================================
# STEP 2. Bastion 전용 deb 수집
# =================================================================
echo ""
echo ">>> [2] Bastion 전용 deb 수집"

PKGS=(
  ansible
  python3-pip
  jq
  net-tools
  kubectl
  apt-utils
)

DEB_COUNT=$(ls "${BASTION_DEBS_DIR}"/*.deb 2>/dev/null | wc -l)
if [ "${DEB_COUNT}" -gt 0 ] && [ -s "${BASTION_DEBS_DIR}/Packages" ]; then
  echo "  ✓ 이미 수집됨 (${DEB_COUNT}개) - skip"
else
  sudo apt-get install --download-only -y "${PKGS[@]}" \
    -o Dir::Cache::archives="${BASTION_DEBS_DIR}" \
    -o Dir::Cache::pkgcache="" \
    -o Dir::Cache::srcpkgcache="" 2>&1 | grep -E "^Get:|already" || true

  sudo rm -f "${BASTION_DEBS_DIR}/lock"
  sudo rm -rf "${BASTION_DEBS_DIR}/partial"

  (cd "${BASTION_DEBS_DIR}" && apt-ftparchive packages . | tee Packages > /dev/null)
  (cd "${BASTION_DEBS_DIR}" && gzip -k -f Packages)

  DEB_COUNT=$(ls "${BASTION_DEBS_DIR}"/*.deb 2>/dev/null | wc -l)
  echo "  ✓ ${DEB_COUNT}개 deb 수집 완료"
fi

# =================================================================
# STEP 3. pip wheel 수집 (ansible 최신버전)
# =================================================================
echo ""
echo ">>> [3] ansible pip wheel 수집"

PIP_DIR="/data/debs/pip"
sudo mkdir -p "${PIP_DIR}"
sudo chown "$(id -u):$(id -g)" "${PIP_DIR}"

PIP_COUNT=$(ls "${PIP_DIR}" 2>/dev/null | wc -l)
if [ "${PIP_COUNT}" -gt 0 ]; then
  echo "  ✓ 이미 수집됨 (${PIP_COUNT}개) - skip"
else
  pip3 download ansible ansible-core -d "${PIP_DIR}" --quiet 2>&1 || true
  PIP_COUNT=$(ls "${PIP_DIR}" 2>/dev/null | wc -l)
  echo "  ✓ ${PIP_COUNT}개 wheel 수집 완료"
fi

# =================================================================
# STEP 4. Ansible Galaxy 컬렉션 수집
# =================================================================
echo ""
echo ">>> [4] Ansible Galaxy 컬렉션 수집"

GALAXY_COUNT=$(ls "${GALAXY_DIR}"/*.tar.gz 2>/dev/null | wc -l)
if [ "${GALAXY_COUNT}" -gt 0 ]; then
  echo "  ✓ 이미 수집됨 (${GALAXY_COUNT}개) - skip"
else
  if ! command -v ansible-galaxy &>/dev/null; then
    sudo apt-get install -y ansible -qq
  fi
  ansible-galaxy collection download \
    community.general \
    community.docker \
    ansible.posix \
    -p "${GALAXY_DIR}"
  GALAXY_COUNT=$(ls "${GALAXY_DIR}"/*.tar.gz 2>/dev/null | wc -l)
  echo "  ✓ ${GALAXY_COUNT}개 컬렉션 수집 완료"
fi


# =================================================================
# STEP 4-b. Monitor VM용 nginx deb 수집
# =================================================================
echo ""
echo ">>> [4-b] Monitor VM용 nginx deb 수집"
set +e

MONITOR_DEBS_DIR="/data/debs/monitor"
sudo rm -rf "${MONITOR_DEBS_DIR}"
sudo mkdir -p "${MONITOR_DEBS_DIR}"
sudo chown -R "$(id -u):$(id -g)" "${MONITOR_DEBS_DIR}"

echo "  deb 다운로드 중..."

# apt-cache depends --recurse로 nginx-core 전체 의존성 추출
# 충돌 패키지(nginx-extras/full/light) 제외 후 apt-get download로 수집
NGINX_ALL_PKGS=$(apt-cache depends --recurse --no-recommends --no-suggests   --no-conflicts --no-breaks --no-replaces --no-enhances   nginx-core 2>/dev/null   | grep "^[A-Za-z]"   | grep -v "^<"   | grep -v -E "^(nginx-extras|nginx-full|nginx-light)"   | sort -u)

echo "  수집 대상 패키지 목록:"
echo "${NGINX_ALL_PKGS}"

cd "${MONITOR_DEBS_DIR}"
for pkg in ${NGINX_ALL_PKGS}; do
  apt-get download "${pkg}" 2>/dev/null && echo "    ✓ ${pkg}" || echo "    skip: ${pkg}"
done
cd - > /dev/null

DOWNLOAD_RC=0
echo "  apt-get 종료코드: ${DOWNLOAD_RC}"

sudo rm -f "${MONITOR_DEBS_DIR}/lock"
sudo rm -rf "${MONITOR_DEBS_DIR}/partial"

(cd "${MONITOR_DEBS_DIR}" && apt-ftparchive packages . | tee Packages > /dev/null)
(cd "${MONITOR_DEBS_DIR}" && gzip -k -f Packages)

MON_DEB_COUNT=$(ls "${MONITOR_DEBS_DIR}"/*.deb 2>/dev/null | wc -l)
echo "  ✓ ${MON_DEB_COUNT}개 nginx deb 수집 완료 (monitor VM용)"
set -e

# =================================================================
# STEP 5. nginx 서빙 확인
# =================================================================
echo ""
echo ">>> [5] nginx 서빙 확인"
sudo nginx -t && sudo systemctl reload nginx

HARBOR_IP=$(hostname -I | awk '{print $1}')
for path in "debs/bastion/Packages" "debs/bastion/Packages" "debs/monitor/Packages" "debs/pip" "galaxy"; do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://${HARBOR_IP}:8080/${path}" 2>/dev/null || echo "000")
  if [ "${HTTP}" = "200" ]; then
    echo "  ✓ http://${HARBOR_IP}:8080/${path}"
  else
    echo "  ✗ http://${HARBOR_IP}:8080/${path} → ${HTTP}"
  fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " A5 완료"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " deb    : http://${HARBOR_IP}:8080/debs/bastion/"
echo " pip    : http://${HARBOR_IP}:8080/debs/pip/"
echo " galaxy : http://${HARBOR_IP}:8080/galaxy/"
echo ""
echo " 다음 단계: Bastion에서 bash 01_prep_bastion.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
#!/bin/bash
# =================================================================
# A5_bastion_pkg_collect.sh - Bastion 전용 deb 번들 수집
#
# [실행 환경] 인터넷 환경의 Ubuntu 22.04 (Jammy) 서버/PC 에서 실행
#             Harbor 서버 또는 로컬 PC (WSL 포함) 에서 실행 가능
#
# [결과물] ./bastion-pkgs/ 디렉토리
#          → 이 디렉토리를 run-bastion.tar.gz 에 포함시켜 베스천에 배포
#
# 실행: bash harbor_process/A5_bastion_pkg_collect.sh
# =================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

OUTPUT_DIR="./bastion-pkgs"
K8S_VERSION="1.30"

echo ">>> Bastion deb 번들 수집 시작"
echo "    출력 경로: ${OUTPUT_DIR}"
echo ""

# K8s 저장소 등록 (kubectl 포함)
echo ">>> K8s 저장소 등록 (kubectl 수집용)"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

sudo apt-get update -qq

# 수집할 패키지 목록
PKGS=(
  ansible
  jq
  curl
  git
  vim
  net-tools
  htop
  chrony
  ca-certificates
  gnupg
  kubectl
  apt-utils        # apt-ftparchive 포함 (Packages 인덱스 생성용)
)

echo ">>> 패키지 다운로드: ${PKGS[*]}"
mkdir -p "${OUTPUT_DIR}"

sudo apt-get install --download-only -y "${PKGS[@]}" \
  -o Dir::Cache::archives="$(realpath ${OUTPUT_DIR})" \
  -o Dir::Cache::pkgcache="" \
  -o Dir::Cache::srcpkgcache=""

# lock 파일 및 partial 디렉토리 제거
sudo rm -f "${OUTPUT_DIR}/lock"
sudo rm -rf "${OUTPUT_DIR}/partial"

# Packages 인덱스 생성
echo ">>> Packages 인덱스 생성"
(cd "${OUTPUT_DIR}" && apt-ftparchive packages . > Packages)
(cd "${OUTPUT_DIR}" && gzip -k -f Packages)

DEB_COUNT=$(ls "${OUTPUT_DIR}"/*.deb 2>/dev/null | wc -l)

# Ansible Galaxy 컬렉션 수집
echo ">>> Ansible Galaxy 컬렉션 수집"
GALAXY_DIR="${OUTPUT_DIR}/galaxy"
mkdir -p "${GALAXY_DIR}"

# ansible-galaxy 없으면 임시 설치
if ! command -v ansible-galaxy &>/dev/null; then
  echo "  ansible-galaxy 없음 → 임시 설치"
  sudo apt-get install -y ansible -qq
fi

ansible-galaxy collection download   community.docker   community.general   -p "${GALAXY_DIR}"

GALAXY_COUNT=$(ls "${GALAXY_DIR}"/*.tar.gz 2>/dev/null | wc -l)
echo "  수집된 컬렉션: ${GALAXY_COUNT}개"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Bastion 패키지 번들 수집 완료"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 수집된 deb: ${DEB_COUNT}개"
echo " 경로: ${OUTPUT_DIR}/"
echo ""
echo " 다음 단계:"
echo "   # tar.gz 으로 압축 (bastion-pkgs/ 포함)"
echo "   tar -czf run-bastion.tar.gz --exclude='*.tar.gz' -C \"\$(dirname \$(pwd))\" \"\$(basename \$(pwd))\""
echo ""
echo "   # 베스천으로 전송"
echo "   scp -i miso-key.pem run-bastion.tar.gz ubuntu@10.1.1.50:~/"
echo ""
echo "   # 베스천에서 실행"
echo "   tar -xzf run-bastion.tar.gz && bash 01_prep_bastion.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
#!/bin/bash
# =================================================================
# A0_harbor_reset.sh - Harbor 서버 완전 초기화
#
# [실행 환경] Harbor 서버(10.1.5.10)에서 직접 실행
#
# [제거 항목]
#   - Harbor 컨테이너 + 이미지 + 데이터
#   - /opt/harbor, /data/harbor, /etc/harbor
#   - /data/{debs,manifests,galaxy}
#   - Docker CE 완전 제거
#   - nginx 완전 제거
#   - apt 저장소 (docker, kubernetes)
#   - 시스템 CA 인증서
#   - /etc/hosts Harbor 항목
#
# 실행: bash A0_harbor_reset.sh
# =================================================================
set -uo pipefail

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Harbor 서버 완전 초기화"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " 경고: 모든 Harbor 데이터와 수집된 패키지가 삭제됩니다."
echo " 5초 후 시작합니다. 중단하려면 Ctrl+C"
echo ""
sleep 5

# =================================================================
# STEP 1. Harbor 컨테이너 중지 및 제거
# =================================================================
echo ">>> [1] Harbor 컨테이너 중지 및 제거"

if [ -f /opt/harbor/docker-compose.yml ]; then
  cd /opt/harbor
  sudo docker compose down -v 2>/dev/null || true
  cd ~
  echo "  ✓ Harbor 컨테이너 중지 완료"
else
  echo "  - docker-compose.yml 없음 (건너뜀)"
fi

# 잔여 harbor 관련 컨테이너 강제 제거
HARBOR_CONTAINERS=$(sudo docker ps -aq \
  --filter "name=harbor" \
  --filter "name=nginx" \
  --filter "name=registry" \
  --filter "name=trivy" 2>/dev/null || true)
if [ -n "${HARBOR_CONTAINERS}" ]; then
  echo "${HARBOR_CONTAINERS}" | xargs sudo docker rm -f 2>/dev/null || true
  echo "  ✓ 잔여 컨테이너 제거"
fi

# Harbor goharbor 이미지 제거
sudo docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null \
  | grep "goharbor" \
  | xargs sudo docker rmi -f 2>/dev/null || true
echo "  ✓ Harbor 이미지 제거"

# Harbor 네트워크 제거
sudo docker network rm harbor_harbor 2>/dev/null || true

# =================================================================
# STEP 2. Harbor 디렉토리 제거
# =================================================================
echo ""
echo ">>> [2] Harbor 디렉토리 제거"

sudo rm -rf /opt/harbor
echo "  ✓ /opt/harbor"

sudo rm -rf /data/harbor
echo "  ✓ /data/harbor"

sudo rm -rf /etc/harbor
echo "  ✓ /etc/harbor"

# =================================================================
# STEP 3. A2/A5 수집 데이터 제거
# =================================================================
echo ""
echo ">>> [3] 수집 데이터 제거 (debs/manifests/galaxy)"

sudo rm -rf /data/debs
echo "  ✓ /data/debs"

sudo rm -rf /data/manifests
echo "  ✓ /data/manifests"

sudo rm -rf /data/galaxy
echo "  ✓ /data/galaxy"

# /data 자체가 비면 제거 (harbor 데이터도 없을 경우)
sudo rmdir /data 2>/dev/null && echo "  ✓ /data (빈 디렉토리 제거)" || true

# =================================================================
# STEP 4. nginx 제거
# =================================================================
echo ""
echo ">>> [4] nginx 제거"

sudo systemctl stop nginx 2>/dev/null || true
sudo systemctl disable nginx 2>/dev/null || true
sudo apt-get purge -y nginx nginx-common nginx-core 2>/dev/null || true
sudo rm -rf /etc/nginx
echo "  ✓ nginx 제거 완료"

# =================================================================
# STEP 5. Docker 완전 제거
# =================================================================
echo ""
echo ">>> [5] Docker 제거"

sudo systemctl stop docker containerd 2>/dev/null || true
sudo systemctl disable docker containerd 2>/dev/null || true

sudo apt-get purge -y \
  docker-ce docker-ce-cli containerd.io \
  docker-compose-plugin docker-ce-rootless-extras \
  2>/dev/null || true

sudo rm -rf /var/lib/docker
sudo rm -rf /var/lib/containerd
sudo rm -rf /etc/docker
echo "  ✓ Docker 제거 완료"

# =================================================================
# STEP 6. apt 저장소 및 키링 제거
# =================================================================
echo ""
echo ">>> [6] apt 저장소 및 키링 제거"

sudo rm -f /etc/apt/sources.list.d/docker.list
sudo rm -f /etc/apt/keyrings/docker.gpg
echo "  ✓ Docker 저장소 제거"

sudo rm -f /etc/apt/sources.list.d/kubernetes.list
sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "  ✓ K8s 저장소 제거"

sudo apt-get update -qq
echo "  ✓ apt 캐시 갱신"

# =================================================================
# STEP 7. 시스템 CA 인증서 제거
# =================================================================
echo ""
echo ">>> [7] 시스템 CA 인증서 제거"

sudo rm -f /usr/local/share/ca-certificates/harbor.crt
sudo rm -f /usr/local/share/ca-certificates/miso-ca.crt
sudo rm -f /tmp/harbor-ca.crt
sudo update-ca-certificates --fresh 2>/dev/null || true
echo "  ✓ CA 인증서 제거 완료"

# =================================================================
# STEP 8. /etc/hosts 정리
# =================================================================
echo ""
echo ">>> [8] /etc/hosts 정리"

sudo sed -i '/harbor\.miso\.local/d' /etc/hosts
echo "  ✓ /etc/hosts 정리 완료"

# =================================================================
# STEP 9. apt 정리
# =================================================================
echo ""
echo ">>> [9] apt 정리"

sudo apt-get autoremove -y 2>/dev/null || true
sudo apt-get clean
echo "  ✓ apt 정리 완료"

# =================================================================
# 완료
# =================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 초기화 완료"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " 다음 단계:"
echo "   scp -i miso-key.pem A1_harbor_install.sh tls.crt tls.key \\"
echo "       ubuntu@10.1.5.10:~/"
echo "   bash A1_harbor_install.sh"
echo "   bash A2_image_collect.sh"
echo "   bash A5_bastion_pkg_collect.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
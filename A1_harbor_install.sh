#!/bin/bash
# =================================================================
# A1_harbor_install.sh - Harbor 레지스트리 설치
#
# [실행 환경] Harbor 서버(10.1.5.10)에서 직접 실행
#             인터넷 연결 필요 (docker, nginx 설치)
#
# [실행 방법]
#   scp -i miso-key.pem A1_harbor_install.sh tls.crt tls.key \
#       ubuntu@10.1.5.10:~/
#   ssh ubuntu@10.1.5.10 "bash A1_harbor_install.sh"
#
# [사전 준비]
#   - tls.crt / tls.key : 같은 디렉토리에 위치 (없으면 자체서명 자동 생성)
#   - harbor-offline-installer-v2.10.2.tgz : 있으면 다운로드 생략
# =================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ★ 도메인/패스워드 변경 시 여기만 수정하세요
#   또는 환경변수로 주입: HARBOR_HOSTNAME=harbor.example.com bash A1_harbor_install.sh
HARBOR_VERSION="${HARBOR_VERSION:-v2.10.2}"
HARBOR_INSTALL_DIR="${HARBOR_INSTALL_DIR:-/opt/harbor}"
HARBOR_DATA_DIR="${HARBOR_DATA_DIR:-/data/harbor}"
HARBOR_HOSTNAME="${HARBOR_HOSTNAME:-harbor.miso.local}"     # ★ 실제 도메인으로 변경
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:-Harbor12345}"  # ★ 변경 권장
HARBOR_CERT_DIR="${HARBOR_CERT_DIR:-/etc/harbor/certs}"
HARBOR_IP=$(hostname -I | awk '{print $1}')

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Harbor 설치 시작"
echo " IP: ${HARBOR_IP}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# =================================================================
# STEP 0. /etc/hosts 등록
# =================================================================
echo ""
echo ">>> [0] /etc/hosts 등록"
if ! grep -q "${HARBOR_HOSTNAME}" /etc/hosts; then
  echo "${HARBOR_IP} ${HARBOR_HOSTNAME}" | sudo tee -a /etc/hosts
fi
echo "  ✓ ${HARBOR_IP} ${HARBOR_HOSTNAME}"

# =================================================================
# STEP 1. 기본 패키지 + nginx 설치
# =================================================================
echo ""
echo ">>> [1] 기본 패키지 + nginx + docker 설치"

sudo apt-get update -qq
sudo apt-get install -y \
  ca-certificates curl gnupg openssl \
  nginx apt-utils

# 기본 80포트 사이트 비활성화 (Harbor가 80/443 점유)
sudo rm -f /etc/nginx/sites-enabled/default
# 8080 서빙 설정 미리 적용 후 시작
sudo mkdir -p /data/debs /data/manifests /data/galaxy
# 현재 유저가 쓸 수 있도록 소유권 설정 (harbor 디렉토리는 건드리지 않음)
sudo chown -R "$(id -u):$(id -g)" /data/debs /data/manifests /data/galaxy
sudo chmod -R 755 /data/debs /data/manifests /data/galaxy
sudo tee /etc/nginx/sites-available/apt-mirror << 'NGINX'
server {
    listen 8080;
    server_name _;
    root /data;
    autoindex on;

    location /debs/     { autoindex on; }
    location /manifests/{ autoindex on; }
    location /galaxy/   { autoindex on; }
}
NGINX
sudo ln -sf /etc/nginx/sites-available/apt-mirror             /etc/nginx/sites-enabled/apt-mirror
sudo systemctl enable --now nginx
echo "  ✓ nginx 설치 및 기동 완료 (포트 8080)"

# Docker 저장소 등록
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu jammy stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update -qq
sudo apt-get install -y \
  docker-ce docker-ce-cli containerd.io docker-compose-plugin

sudo systemctl enable --now docker
sudo usermod -aG docker ubuntu || true
echo "  ✓ docker 설치 완료"

# =================================================================
# STEP 2. TLS 인증서 준비
# =================================================================
echo ""
echo ">>> [2] TLS 인증서 준비"

sudo mkdir -p "${HARBOR_CERT_DIR}"

if [ -f "${SCRIPT_DIR}/tls.crt" ] && [ -f "${SCRIPT_DIR}/tls.key" ]; then
  echo "  외부 인증서 사용: tls.crt / tls.key"
  sudo cp "${SCRIPT_DIR}/tls.crt" "${HARBOR_CERT_DIR}/harbor.crt"
  sudo cp "${SCRIPT_DIR}/tls.key" "${HARBOR_CERT_DIR}/harbor.key"
  sudo chmod 600 "${HARBOR_CERT_DIR}/harbor.key"
  # CA 인증서도 복사 (있을 때 - A3에서 K8s 노드에 배포)
  if [ -f "${SCRIPT_DIR}/ca.crt" ]; then
    sudo cp "${SCRIPT_DIR}/ca.crt" "${HARBOR_CERT_DIR}/ca.crt"
    echo "  ✓ ca.crt 복사 완료 (A3에서 K8s 노드 배포용)"
  fi
else
  echo "  자체서명 인증서 생성"
  sudo openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
    -keyout "${HARBOR_CERT_DIR}/harbor.key" \
    -out    "${HARBOR_CERT_DIR}/harbor.crt" \
    -subj "/CN=${HARBOR_HOSTNAME}" \
    -addext "subjectAltName=DNS:${HARBOR_HOSTNAME},IP:${HARBOR_IP}"
fi

# 시스템 CA 신뢰 등록 (ca.crt 우선, 없으면 harbor.crt)
if [ -f "${HARBOR_CERT_DIR}/ca.crt" ]; then
  sudo cp "${HARBOR_CERT_DIR}/ca.crt"           /usr/local/share/ca-certificates/miso-ca.crt
else
  sudo cp "${HARBOR_CERT_DIR}/harbor.crt"           /usr/local/share/ca-certificates/miso-ca.crt
fi
sudo update-ca-certificates
echo "  ✓ 인증서 준비 완료"

# =================================================================
# STEP 3. Harbor 설치
# =================================================================
echo ""
echo ">>> [3] Harbor 설치"

sudo mkdir -p "${HARBOR_INSTALL_DIR}" "${HARBOR_DATA_DIR}"

# Harbor 각 서비스 데이터 디렉토리 사전 생성 및 권한 설정
# Redis 컨테이너 UID=999, registry/postgresql UID=10000
sudo mkdir -p "${HARBOR_DATA_DIR}"/{redis,registry,database,job_logs,trivy-adapter,secret}
sudo chown -R 999:999     "${HARBOR_DATA_DIR}/redis"
sudo chown -R 10000:10000 "${HARBOR_DATA_DIR}/registry"
sudo chmod 755 "${HARBOR_DATA_DIR}/redis" "${HARBOR_DATA_DIR}/registry"

INSTALLER_TGZ="${SCRIPT_DIR}/harbor-offline-installer-${HARBOR_VERSION}.tgz"
INSTALLER_DEST="${HOME}/harbor-offline-installer-${HARBOR_VERSION}.tgz"

if [ -f "${INSTALLER_TGZ}" ]; then
  echo "  로컬 installer 사용"
  [ "${INSTALLER_TGZ}" != "${INSTALLER_DEST}" ] && cp "${INSTALLER_TGZ}" "${INSTALLER_DEST}" || true
else
  echo "  installer 다운로드 중..."
  curl -fL \
    "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-offline-installer-${HARBOR_VERSION}.tgz" \
    -o "${INSTALLER_DEST}"
fi

# 압축 해제
if [ ! -f "${HARBOR_INSTALL_DIR}/harbor.yml.tmpl" ]; then
  sudo tar -xzf "${INSTALLER_DEST}" -C "${HARBOR_INSTALL_DIR}" \
    --strip-components=1
fi

# harbor.yml 생성
if [ ! -f "${HARBOR_INSTALL_DIR}/harbor.yml" ]; then
  sudo cp "${HARBOR_INSTALL_DIR}/harbor.yml.tmpl" \
          "${HARBOR_INSTALL_DIR}/harbor.yml"
  sudo sed -i "s|^hostname:.*|hostname: ${HARBOR_HOSTNAME}|" \
    "${HARBOR_INSTALL_DIR}/harbor.yml"
  sudo sed -i "s|certificate: /your/certificate/path|certificate: ${HARBOR_CERT_DIR}/harbor.crt|" \
    "${HARBOR_INSTALL_DIR}/harbor.yml"
  sudo sed -i "s|private_key: /your/private/key/path|private_key: ${HARBOR_CERT_DIR}/harbor.key|" \
    "${HARBOR_INSTALL_DIR}/harbor.yml"
  sudo sed -i "s|harbor_admin_password:.*|harbor_admin_password: ${HARBOR_ADMIN_PASSWORD}|" \
    "${HARBOR_INSTALL_DIR}/harbor.yml"
  sudo sed -i "s|data_volume:.*|data_volume: ${HARBOR_DATA_DIR}|" \
    "${HARBOR_INSTALL_DIR}/harbor.yml"
fi

# Harbor 설치 실행
if [ ! -f "${HARBOR_INSTALL_DIR}/docker-compose.yml" ]; then
  cd "${HARBOR_INSTALL_DIR}"
  sudo ./install.sh --with-trivy
  cd -
fi

# =================================================================
# STEP 4. Harbor 기동 대기
# =================================================================
echo ""
echo ">>> [4] Harbor 기동 대기 (최대 5분)"

for i in $(seq 1 60); do
  if curl -sk "https://${HARBOR_IP}/api/v2.0/health" | grep -q "healthy"; then
    echo "  ✓ Harbor 정상 기동 (${i}번째 시도)"
    break
  fi
  echo "  대기 중... (${i}/60)"
  sleep 5
done

# =================================================================
# STEP 5. miso 프로젝트 생성
# =================================================================
echo ""
echo ">>> [5] Harbor 프로젝트 'miso' 생성"

HTTP_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" \
  -X POST "https://${HARBOR_IP}/api/v2.0/projects" \
  -u "admin:${HARBOR_ADMIN_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d '{"project_name":"miso","public":false}')

if [ "${HTTP_STATUS}" = "201" ]; then
  echo "  ✓ miso 프로젝트 생성 완료"
elif [ "${HTTP_STATUS}" = "409" ]; then
  echo "  ✓ miso 프로젝트 이미 존재"
else
  echo "  ✗ 프로젝트 생성 실패 (HTTP ${HTTP_STATUS})"
fi

# =================================================================
# STEP 5-b. Robot Account 생성 (pull 전용 - 노드 배포용)
# =================================================================
echo ""
echo ">>> [5-b] Harbor Robot Account 생성 (pull 전용)"

ROBOT_NAME="node-pull"
ROBOT_SECRET_FILE="${SCRIPT_DIR}/harbor-robot-secret.txt"

# Harbor 2.x 시스템 레벨 robot API 사용
ROBOT_PAYLOAD=$(cat <<EOF
{
  "name": "${ROBOT_NAME}",
  "description": "Pull-only robot for K8s nodes",
  "duration": -1,
  "level": "project",
  "permissions": [
    {
      "kind": "project",
      "namespace": "miso",
      "access": [
        {"resource": "repository", "action": "pull"}
      ]
    }
  ]
}
EOF
)

ROBOT_RESP=$(curl -sk -w "\n%{http_code}" \
  -X POST "https://${HARBOR_IP}/api/v2.0/robots" \
  -u "admin:${HARBOR_ADMIN_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d "${ROBOT_PAYLOAD}")

HTTP_STATUS=$(echo "${ROBOT_RESP}" | tail -1)
ROBOT_BODY=$(echo "${ROBOT_RESP}" | sed '$d')

if [ "${HTTP_STATUS}" = "201" ]; then
  ROBOT_SECRET=$(echo "${ROBOT_BODY}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['secret'])")
  ROBOT_USER=$(echo "${ROBOT_BODY}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['name'])")
  echo "${ROBOT_USER}:${ROBOT_SECRET}" > "${ROBOT_SECRET_FILE}"
  chmod 600 "${ROBOT_SECRET_FILE}"
  echo "  ✓ Robot account 생성: ${ROBOT_USER}"
  echo "  ✓ Secret 저장: ${ROBOT_SECRET_FILE}"
elif [ "${HTTP_STATUS}" = "409" ]; then
  echo "  ✓ Robot account 이미 존재 - 재생성"
  # 기존 삭제 후 재생성
  ROBOT_ID=$(curl -sk "https://${HARBOR_IP}/api/v2.0/robots?q=name%3D%24miso%2B${ROBOT_NAME}" \
    -u "admin:${HARBOR_ADMIN_PASSWORD}" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r[0]['id']) if r else print('')")
  if [ -n "${ROBOT_ID}" ]; then
    curl -sk -X DELETE "https://${HARBOR_IP}/api/v2.0/robots/${ROBOT_ID}" \
      -u "admin:${HARBOR_ADMIN_PASSWORD}" > /dev/null
    # 재귀 없이 재실행 - 잠시 대기 후 다시 호출
    sleep 2
    ROBOT_RESP2=$(curl -sk -w "\n%{http_code}" \
      -X POST "https://${HARBOR_IP}/api/v2.0/robots" \
      -u "admin:${HARBOR_ADMIN_PASSWORD}" \
      -H "Content-Type: application/json" \
      -d "${ROBOT_PAYLOAD}")
    HTTP_STATUS2=$(echo "${ROBOT_RESP2}" | tail -1)
    ROBOT_BODY2=$(echo "${ROBOT_RESP2}" | sed '$d')
    if [ "${HTTP_STATUS2}" = "201" ]; then
      ROBOT_SECRET=$(echo "${ROBOT_BODY2}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['secret'])")
      ROBOT_USER=$(echo "${ROBOT_BODY2}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['name'])")
      echo "${ROBOT_USER}:${ROBOT_SECRET}" > "${ROBOT_SECRET_FILE}"
      chmod 600 "${ROBOT_SECRET_FILE}"
      echo "  ✓ Robot account 재생성: ${ROBOT_USER}"
    fi
  fi
else
  echo "  ✗ Robot account 생성 실패 (HTTP ${HTTP_STATUS})"
  echo "  응답: ${ROBOT_BODY}"
fi

# =================================================================
# STEP 6. nginx apt mirror 서빙 설정
# =================================================================
echo ""
echo ">>> [6] nginx apt mirror 서빙 확인"
sudo nginx -t && sudo systemctl reload nginx
echo "  ✓ nginx :8080 서빙 준비 완료"

# =================================================================
# 완료
# =================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Harbor 설치 완료"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " UI      : https://${HARBOR_HOSTNAME}"
echo " Admin   : admin / ${HARBOR_ADMIN_PASSWORD}"
echo " 프로젝트: miso (private)"
echo ""
echo " 다음 단계:"
echo "   bash A2_image_collect.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
#!/bin/bash
# =================================================================
# 00_gen_certs.sh
# 작업 PC에서 1회 실행 - *.miso.local 와일드카드 인증서 생성
#
# 실행: bash 00_gen_certs.sh
#
# 생성 파일:
#   ca.crt        → 접속 PC(Windows/macOS)에 설치
#   ca.key        → 보관용 (외부 유출 금지)
#   tls.crt       → 베스천 플레이북 디렉토리에 복사
#   tls.key       → 베스천 플레이북 디렉토리에 복사
# =================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOMAIN="miso.local"
WILDCARD="*.${DOMAIN}"
DAYS_CA=3650    # CA 유효기간 10년
DAYS_CERT=3650  # 인증서 유효기간 10년

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " *.miso.local 와일드카드 인증서 생성"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ---------------------------------------------------------------
# 1. Root CA 생성
# ---------------------------------------------------------------
echo ""
echo ">>> [1/3] Root CA 생성 (ca.key, ca.crt)"

openssl genrsa -out "${SCRIPT_DIR}/ca.key" 4096

openssl req -x509 -new -nodes \
  -key "${SCRIPT_DIR}/ca.key" \
  -sha256 \
  -days ${DAYS_CA} \
  -out "${SCRIPT_DIR}/ca.crt" \
  -subj "/C=KR/ST=Seoul/L=Seoul/O=MISO/OU=IT/CN=MISO Root CA"

echo "    완료: ca.key, ca.crt"

# ---------------------------------------------------------------
# 2. 와일드카드 인증서 CSR 생성
# ---------------------------------------------------------------
echo ""
echo ">>> [2/3] 와일드카드 인증서 생성 (tls.key, tls.crt)"

openssl genrsa -out "${SCRIPT_DIR}/tls.key" 4096

# SAN 설정 파일 (Subject Alternative Names)
cat > /tmp/miso-san.cnf << SANEOF
[req]
req_extensions     = v3_req
distinguished_name = req_distinguished_name
prompt             = no

[req_distinguished_name]
C  = KR
ST = Seoul
L  = Seoul
O  = MISO
OU = IT
CN = *.miso.local

[v3_req]
keyUsage         = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt_names

[alt_names]
DNS.1 = *.miso.local
DNS.2 = miso.local
SANEOF

# CSR 생성
openssl req -new \
  -key "${SCRIPT_DIR}/tls.key" \
  -out /tmp/miso-tls.csr \
  -config /tmp/miso-san.cnf

# CA로 서명
cat > /tmp/miso-ext.cnf << EXTEOF
authorityKeyIdentifier = keyid,issuer
basicConstraints       = CA:FALSE
keyUsage               = digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
subjectAltName         = @alt_names

[alt_names]
DNS.1 = *.miso.local
DNS.2 = miso.local
EXTEOF

openssl x509 -req \
  -in /tmp/miso-tls.csr \
  -CA "${SCRIPT_DIR}/ca.crt" \
  -CAkey "${SCRIPT_DIR}/ca.key" \
  -CAcreateserial \
  -out "${SCRIPT_DIR}/tls.crt" \
  -days ${DAYS_CERT} \
  -sha256 \
  -extfile /tmp/miso-ext.cnf

echo "    완료: tls.key, tls.crt"

# ---------------------------------------------------------------
# 검증
# ---------------------------------------------------------------
echo ""
echo ">>> 인증서 검증"
openssl verify -CAfile "${SCRIPT_DIR}/ca.crt" "${SCRIPT_DIR}/tls.crt" \
  && echo "    ✅ 인증서 검증 성공" \
  || echo "    ❌ 인증서 검증 실패"

echo ""
echo ">>> SAN 확인"
openssl x509 -in "${SCRIPT_DIR}/tls.crt" -noout -text \
  | grep -A3 "Subject Alternative Name"

# ---------------------------------------------------------------
# 완료 안내
# ---------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 생성 완료"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ls -lh "${SCRIPT_DIR}"/{ca.crt,ca.key,tls.crt,tls.key}
echo ""
echo " 다음 단계:"
echo ""
echo " [1] 접속 PC에 CA 인증서 설치 (ca.crt)"
echo "     → Windows : 00_install_ca_windows.bat 실행 (관리자 권한)"
echo "     → macOS   : bash 00_install_ca_macos.sh 실행"
echo ""
echo " [2] 베스천에 인증서 파일 복사"
echo "     scp -i miso-key.pem ca.crt tls.crt tls.key \\"
echo "       harbor.miso.local.crt harbor.miso.local.key \\"
echo "       ubuntu@<BASTION_IP>:~/run-bastion/"
echo ""
echo " [3] SSL 적용 플레이북 실행"
echo "     ansible-playbook -i hosts.ini 19_ssl_setup.yml"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
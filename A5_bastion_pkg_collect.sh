#!/bin/bash
# =================================================================
# A5_bastion_pkg_collect.sh - Bastion / Monitor 전용 패키지 수집
#
# [실행 환경] Harbor 서버 (10.1.5.10) 에서 실행
#             A1, A2 완료 후 실행
#
# [결과물]
#   /data/debs/bastion/  -> Bastion용 deb repo
#   /data/debs/monitor/  -> Monitor VM용 deb repo
#   /data/debs/pip/      -> pip wheel
#   /data/galaxy/        -> Ansible Galaxy collections
#
# [서빙 주소]
#   http://<harbor_ip>:8080/debs/bastion/
#   http://<harbor_ip>:8080/debs/monitor/
#   http://<harbor_ip>:8080/debs/pip/
#   http://<harbor_ip>:8080/galaxy/
#
# 실행: bash A5_bastion_pkg_collect.sh
# =================================================================

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

BASTION_DEBS_DIR="/data/debs/bastion"
MONITOR_DEBS_DIR="/data/debs/monitor"
PIP_DIR="/data/debs/pip"
GALAXY_DIR="/data/galaxy"
K8S_VERSION="1.30"
KUBECTL_DEB_VERSION="1.30.14-1.1"  # kubectl deb 버전 (A2 K8S_DEB_VERSION과 동기화)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " A5: Bastion / Monitor 전용 패키지 수집"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# =================================================================
# 공통 함수
# =================================================================
log() {
  echo "[A5] $*"
}

ensure_dir() {
  local dir="$1"
  sudo mkdir -p "$dir"
  sudo chown -R "$(id -u):$(id -g)" "$dir"
}

reset_repo_dir() {
  local dir="$1"
  sudo rm -rf "$dir"
  sudo mkdir -p "$dir"
  sudo chown -R "$(id -u):$(id -g)" "$dir"
}

ensure_apt_tools() {
  log "apt 도구 설치 확인"
  sudo apt-get update -qq
  sudo apt-get install -y -qq apt-rdepends apt-utils ca-certificates gnupg curl >/dev/null
}

ensure_k8s_repo() {
  echo ""
  echo ">>> [1] K8s 저장소 등록"
  sudo mkdir -p /etc/apt/keyrings

  if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ] || \
     [ ! -f /etc/apt/sources.list.d/kubernetes.list ]; then
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
      | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
      | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

    echo "  ✓ K8s 저장소 등록 완료"
  else
    echo "  ✓ K8s 저장소 이미 등록됨 (skip)"
  fi

  sudo apt-get update -qq
}

resolve_pkg_closure() {
  apt-rdepends "$@" 2>/dev/null \
    | awk '/^[[:alnum:]][[:alnum:]+.-]*$/ {print}' \
    | sort -u
}

download_pkg_set() {
  local outdir="$1"
  shift
  local pkgs=("$@")

  cd "$outdir" || return 1

  local failed=0
  local pkg
  for pkg in "${pkgs[@]}"; do
    if apt-get download "$pkg" >/dev/null 2>&1; then
      echo "    ✓ $pkg"
    else
      echo "    ✗ $pkg"
      failed=1
    fi
  done

  cd - >/dev/null || true
  return $failed
}

build_packages_index() {
  local dir="$1"
  (cd "$dir" && apt-ftparchive packages . | tee Packages >/dev/null)
  (cd "$dir" && gzip -k -f Packages)
}

verify_repo_has_packages() {
  local dir="$1"
  shift
  local required=("$@")
  local missing=0
  local pkg

  echo "  필수 패키지 검증:"
  for pkg in "${required[@]}"; do
    if grep -q "^Package: ${pkg}$" "${dir}/Packages"; then
      echo "    ✓ ${pkg}"
    else
      echo "    ✗ ${pkg} 없음"
      missing=1
    fi
  done

  return $missing
}

serve_check() {
  local harbor_ip="$1"
  shift
  local path
  for path in "$@"; do
    local http
    http=$(curl -s -o /dev/null -w "%{http_code}" "http://${harbor_ip}:8080/${path}" 2>/dev/null || echo "000")
    if [ "$http" = "200" ]; then
      echo "  ✓ http://${harbor_ip}:8080/${path}"
    else
      echo "  ✗ http://${harbor_ip}:8080/${path} -> ${http}"
      return 1
    fi
  done
  return 0
}

# =================================================================
# 초기 디렉토리 준비
# =================================================================
ensure_dir "${BASTION_DEBS_DIR}"
ensure_dir "${MONITOR_DEBS_DIR}"
ensure_dir "${PIP_DIR}"
ensure_dir "${GALAXY_DIR}"

ensure_apt_tools
ensure_k8s_repo

# =================================================================
# STEP 2. Bastion 전용 deb 수집
# =================================================================
echo ""
echo ">>> [2] Bastion 전용 deb 수집"

BASTION_ROOT_PKGS=(
  ansible
  python3-pip
  jq
  net-tools
  kubectl
  apt-utils
)

# apt-rdepends용 패키지명만 (버전 제외), download시에는 버전 고정
BASTION_DOWNLOAD_PKGS=(
  ansible
  python3-pip
  jq
  net-tools
  "kubectl=${KUBECTL_DEB_VERSION}"
  apt-utils
)

echo "  의존성 포함 전체 패키지 목록 계산 중..."
# apt-rdepends는 패키지명만 받음 (버전 지정 불가)
mapfile -t BASTION_DEP_PKGS < <(resolve_pkg_closure "${BASTION_ROOT_PKGS[@]}")

if [ "${#BASTION_DEP_PKGS[@]}" -eq 0 ]; then
  echo "  ✗ Bastion 패키지 목록 계산 실패"
  exit 1
fi

# 버전 고정 패키지로 덮어쓰기 (kubectl 등)
# BASTION_DEP_PKGS에서 버전 고정 대상 패키지명 제거 후 BASTION_DOWNLOAD_PKGS 병합
BASTION_VERSIONED_NAMES=(kubectl)
mapfile -t BASTION_FILTERED_PKGS < <(
  printf '%s\n' "${BASTION_DEP_PKGS[@]}" \
    | grep -vxF "$(printf '%s\n' "${BASTION_VERSIONED_NAMES[@]}")"
)
BASTION_ALL_PKGS=("${BASTION_FILTERED_PKGS[@]}" "${BASTION_DOWNLOAD_PKGS[@]}")

echo "  총 ${#BASTION_ALL_PKGS[@]}개 패키지 후보"
reset_repo_dir "${BASTION_DEBS_DIR}"

echo "  apt-get download로 수집 중..."
if ! download_pkg_set "${BASTION_DEBS_DIR}" "${BASTION_ALL_PKGS[@]}"; then
  echo "  ! 일부 패키지 다운로드 실패가 있었음 (필수 패키지 검증 진행)"
fi

build_packages_index "${BASTION_DEBS_DIR}"

BASTION_DEB_COUNT=$(find "${BASTION_DEBS_DIR}" -maxdepth 1 -name "*.deb" | wc -l)
echo "  ✓ ${BASTION_DEB_COUNT}개 deb 수집 완료"

if ! verify_repo_has_packages "${BASTION_DEBS_DIR}" ansible kubectl python3-pip; then
  echo "  ✗ Bastion repo 필수 패키지 누락"
  exit 1
fi

# =================================================================
# STEP 3. pip wheel 수집
# =================================================================
echo ""
echo ">>> [3] ansible pip wheel 수집"

ensure_dir "${PIP_DIR}"

if ! command -v pip3 >/dev/null 2>&1; then
  echo "  pip3 없음 -> 설치 시도"
  sudo apt-get install -y -qq python3-pip >/dev/null || true
fi

if command -v pip3 >/dev/null 2>&1; then
  pip3 download ansible ansible-core -d "${PIP_DIR}" --quiet 2>/dev/null || true
  PIP_COUNT=$(find "${PIP_DIR}" -maxdepth 1 | wc -l)
  echo "  ✓ pip wheel 수집 완료 (항목 수: ${PIP_COUNT})"
else
  echo "  ! pip3 설치 실패 - pip wheel 수집 건너뜀"
fi

# =================================================================
# STEP 4. Ansible Galaxy 컬렉션 수집
# =================================================================
echo ""
echo ">>> [4] Ansible Galaxy 컬렉션 수집"

if ! command -v ansible-galaxy >/dev/null 2>&1; then
  echo "  ansible-galaxy 없음 -> ansible 설치 시도"
  sudo apt-get install -y -qq ansible >/dev/null || true
fi

if command -v ansible-galaxy >/dev/null 2>&1; then
  ansible-galaxy collection download \
    community.general \
    community.docker \
    ansible.posix \
    -p "${GALAXY_DIR}" >/dev/null 2>&1 || true

  GALAXY_COUNT=$(find "${GALAXY_DIR}" -maxdepth 1 -name "*.tar.gz" | wc -l)
  echo "  ✓ ${GALAXY_COUNT}개 컬렉션 수집 완료"
else
  echo "  ! ansible-galaxy 설치 실패 - galaxy 수집 건너뜀"
fi

# =================================================================
# STEP 4-b. Monitor VM용 nginx-core deb 수집
# =================================================================
echo ""
echo ">>> [4-b] Monitor VM용 nginx-core deb 수집"

MONITOR_ROOT_PKGS=(
  nginx-core
)

echo "  의존성 포함 전체 패키지 목록 계산 중..."
mapfile -t MONITOR_ALL_PKGS < <(
  resolve_pkg_closure "${MONITOR_ROOT_PKGS[@]}" \
    | grep -vE '^(nginx|nginx-full|nginx-light|nginx-extras)$'
)

if [ "${#MONITOR_ALL_PKGS[@]}" -eq 0 ]; then
  echo "  ✗ Monitor 패키지 목록 계산 실패"
  exit 1
fi

echo "  총 ${#MONITOR_ALL_PKGS[@]}개 패키지 후보"
reset_repo_dir "${MONITOR_DEBS_DIR}"

echo "  apt-get download로 수집 중..."
if ! download_pkg_set "${MONITOR_DEBS_DIR}" "${MONITOR_ALL_PKGS[@]}"; then
  echo "  ! 일부 패키지 다운로드 실패가 있었음 (필수 패키지 검증 진행)"
fi

build_packages_index "${MONITOR_DEBS_DIR}"

MONITOR_DEB_COUNT=$(find "${MONITOR_DEBS_DIR}" -maxdepth 1 -name "*.deb" | wc -l)
echo "  ✓ ${MONITOR_DEB_COUNT}개 nginx-core deb 수집 완료"

if ! verify_repo_has_packages "${MONITOR_DEBS_DIR}" nginx-core nginx-common; then
  echo "  ✗ Monitor repo 필수 패키지 누락"
  exit 1
fi

# =================================================================
# STEP 5. nginx 서빙 확인
# =================================================================
echo ""
echo ">>> [5] nginx 서빙 확인"
if ! sudo nginx -t; then
  echo "  ✗ nginx 설정 검증 실패"
  exit 1
fi

if ! sudo systemctl restart nginx; then
  echo "  ✗ nginx 재시작 실패"
  exit 1
fi

HARBOR_IP=$(hostname -I | awk '{print $1}')

if ! serve_check "${HARBOR_IP}" \
  "debs/bastion/Packages" \
  "debs/monitor/Packages" \
  "debs/pip/" \
  "galaxy/"; then
  echo "  ✗ nginx 서빙 확인 실패"
  exit 1
fi

# =================================================================
# 완료 안내
# =================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " A5 완료"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " deb bastion : http://${HARBOR_IP}:8080/debs/bastion/"
echo " deb monitor : http://${HARBOR_IP}:8080/debs/monitor/"
echo " pip         : http://${HARBOR_IP}:8080/debs/pip/"
echo " galaxy      : http://${HARBOR_IP}:8080/galaxy/"
echo ""
echo " 다음 단계:"
echo "   Bastion에서 bash 01_prep_bastion.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
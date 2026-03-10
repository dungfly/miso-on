#!/bin/bash
# =================================================================
# 01_prep_bastion.sh - 베스천 초기 설정
#
# ⚠️  반드시 sudo 없이 실행:
#    bash 01_prep_bastion.sh
#    (sudo 실행 시 SSH 키가 /root/.ssh/ 에 생성되어 이후 플레이북 실패)
#
# [실행 환경 분기]
#   인터넷 환경 : 외부 저장소에서 직접 설치 (기본)
#   폐쇄망 환경 : ./bastion-pkgs/ 디렉토리의 deb 번들로 설치
#                 사전 준비: bash harbor_process/A5_bastion_pkg_collect.sh
#                            (인터넷 환경 PC/서버에서 1회 실행 후 번들 복사)
# =================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# root 실행 차단
if [ "$(id -u)" -eq 0 ]; then
  echo "!!! 오류: root(sudo) 로 실행하면 안 됩니다."
  echo "!!!        bash 01_prep_bastion.sh 로 다시 실행하세요."
  exit 1
fi

# needrestart 팝업 방지
if [ -f /etc/needrestart/needrestart.conf ]; then
  sudo sed -i "s/#\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/" \
    /etc/needrestart/needrestart.conf
  # 커널 업데이트 힌트 팝업 억제
  sudo sed -i "s/^#\?\$nrconf{kernelhints}.*/\$nrconf{kernelhints} = -1;/" \
    /etc/needrestart/needrestart.conf
fi

echo ">>> [Bastion] 관리 서버 설정을 시작합니다."

# =================================================================
# 1. 패키지 설치 (인터넷 / 폐쇄망 자동 분기)
# =================================================================
# 이미 설치된 패키지 제외 - ansible/kubectl/jq/net-tools 등 없는 것만 설치
BASTION_PKGS_COMMON="ansible python3-pip jq net-tools"
HARBOR_REPO="http://10.1.5.10:8080/debs"

# -------------------------------------------------------
# Harbor 로컬 저장소 사용 (폐쇄망 기본)
# Harbor가 먼저 구성되어 있어야 함
# -------------------------------------------------------
echo ">>> [로컬저장소] Harbor nginx 저장소에서 설치합니다."

# Harbor 로컬 저장소 등록 (bastion 전용 - Harbor 서버와 동일 버전)
sudo tee /etc/apt/sources.list.d/miso-local-bastion.list << APTEOF
deb [trusted=yes] ${HARBOR_REPO}/bastion ./
APTEOF

sudo tee /etc/apt/sources.list.d/miso-local-k8s.list << APTEOF
deb [trusted=yes] ${HARBOR_REPO}/k8s ./
APTEOF

# [1단계] 외부 저장소 완전 비활성화
sudo rm -f /etc/apt/sources.list.d/kubernetes.list
if [ -f /etc/apt/sources.list ] && ! grep -q "^#.*DISABLED" /etc/apt/sources.list; then
  sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
  sudo sed -i 's/^deb /#DISABLED deb /g' /etc/apt/sources.list
  sudo sed -i 's/^deb-src /#DISABLED deb-src /g' /etc/apt/sources.list
fi
for f in /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/*.list; do
  [ -f "$f" ] || continue
  case "$f" in
    *miso-local-bastion*|*miso-local-k8s*) continue ;;
  esac
  sudo sed -i 's/^deb /#DISABLED deb /g' "$f" 2>/dev/null || true
done

sudo apt-get update -qq

# 이미 설치된 패키지는 건너뛰고 없는 것만 설치 (버전 충돌 방지)
PKGS_TO_INSTALL=""
for pkg in ${BASTION_PKGS_COMMON} kubectl; do
  # python3-pip은 항상 설치 시도 (pip3 명령 보장)
  if [ "${pkg}" = "python3-pip" ]; then
    PKGS_TO_INSTALL="${PKGS_TO_INSTALL} ${pkg}"
  elif dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
    echo "  [skip] ${pkg} 이미 설치됨"
  else
    PKGS_TO_INSTALL="${PKGS_TO_INSTALL} ${pkg}"
  fi
done

if [ -n "${PKGS_TO_INSTALL}" ]; then
  echo "  설치할 패키지: ${PKGS_TO_INSTALL}"
  sudo apt-get install -y --no-install-recommends ${PKGS_TO_INSTALL}
else
  echo "  모든 패키지 이미 설치됨"
fi

echo ">>> 패키지 설치 완료"
kubectl version --client=true

# =================================================================
# 1-b. Ansible 최신버전 pip 설치 (Harbor nginx wheel)
# =================================================================
echo ">>> Ansible pip wheel 설치 (Harbor에서)"
pip3 install ansible   --no-index   --find-links "http://10.1.5.10:8080/debs/pip/"   --trusted-host 10.1.5.10   -q
echo "  ✓ $(ansible --version | head -1)"

# =================================================================
# 1-c. Ansible Galaxy 컬렉션 설치 (Harbor nginx tarball)
# =================================================================
echo ">>> Ansible Galaxy 컬렉션 설치"
GALAXY_TMP=$(mktemp -d)
# Harbor galaxy 디렉토리에서 파일 목록을 가져와 설치
GALAXY_FILES=$(curl -s "http://10.1.5.10:8080/galaxy/"   | grep -oE '[a-z]+-[a-z_]+-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz'   | sort -u)

for fname in ${GALAXY_FILES}; do
  curl -s "http://10.1.5.10:8080/galaxy/${fname}" -o "${GALAXY_TMP}/${fname}"
  ansible-galaxy collection install "${GALAXY_TMP}/${fname}"     -p ~/.ansible/collections -q 2>/dev/null || true
  echo "  ✓ ${fname}"
done
rm -rf "${GALAXY_TMP}" 

# =================================================================
# 2. miso-key.pem 설치
# =================================================================
if [ -f "$PWD/miso-key.pem" ]; then
  echo ">>> miso-key.pem 설치"
  mkdir -p ~/.ssh
  cp "$PWD/miso-key.pem" ~/.ssh/miso-key.pem
  chmod 600 ~/.ssh/miso-key.pem
else
  echo "!!! 경고: $PWD/miso-key.pem 파일이 없습니다."
  echo "!!!        스크립트와 같은 위치에 miso-key.pem 을 넣고 다시 실행하세요."
  exit 1
fi

# =================================================================
# 3. SSH 키 생성 (베스천 자체 관리용)
# =================================================================
if [ ! -f ~/.ssh/id_rsa ]; then
  echo ">>> SSH 키 생성"
  ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
fi
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# =================================================================
# 4. 시간 동기화 및 타임존 설정
# =================================================================
sudo timedatectl set-timezone Asia/Seoul
sudo systemctl enable --now chrony

sudo touch /var/log/ansible.log
sudo chmod 666 /var/log/ansible.log

# =================================================================
# 5. haproxy.cfg.j2 CRLF 정리 (Windows 편집 파일 대응)
# =================================================================
if [ -f "$PWD/haproxy.cfg.j2" ]; then
  echo ">>> haproxy.cfg.j2 CRLF 정리"
  sed -i 's/\r//' "$PWD/haproxy.cfg.j2"
  [ -n "$(tail -c1 "$PWD/haproxy.cfg.j2")" ] && echo "" >> "$PWD/haproxy.cfg.j2"
fi

# =================================================================
# 6. Ansible 실행
# =================================================================
ansible-playbook -i localhost, bastion_setup.yml

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Bastion 준비 완료"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 다음 단계:"
echo "   ansible-playbook -i hosts.ini harbor_process/A4_local_repo_setup.yml"
echo "   ansible-playbook -i hosts.ini phase1_infra_base.yml"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
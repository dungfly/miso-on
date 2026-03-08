#!/bin/bash
# =================================================================
# 00_prepare_manifests.sh
# 플레이북 실행 전 manifest 파일 사전 다운로드
#
# 인터넷이 되는 환경(베스천 or 로컬 PC)에서 1회 실행
# 실행: bash 00_prepare_manifests.sh
#
# 생성 파일 (플레이북과 같은 디렉토리):
#   argocd-install.yaml
#   argocd-image-updater.yaml
# =================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARGOCD_VERSION="v2.10.3"
IMAGE_UPDATER_VERSION="v1.0.2"

echo ">>> 저장 경로: ${SCRIPT_DIR}"
echo ""

# ---------------------------------------------------------------
# 1. ArgoCD
# ---------------------------------------------------------------
echo ">>> [1/2] ArgoCD ${ARGOCD_VERSION} manifest 다운로드"
curl -fsSL \
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" \
  -o "${SCRIPT_DIR}/argocd-install.yaml"
echo "    완료: argocd-install.yaml ($(wc -l < ${SCRIPT_DIR}/argocd-install.yaml) lines)"

# ---------------------------------------------------------------
# 2. ArgoCD Image Updater
#    GitHub Release Assets에서 직접 다운로드 (가장 안정적)
# ---------------------------------------------------------------
echo ">>> [2/2] ArgoCD Image Updater ${IMAGE_UPDATER_VERSION} manifest 다운로드"
curl -fsSL \
  "https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/config/install.yaml" \
  -o "${SCRIPT_DIR}/argocd-image-updater.yaml"
echo "    완료: argocd-image-updater.yaml ($(wc -l < ${SCRIPT_DIR}/argocd-image-updater.yaml) lines)"

# ---------------------------------------------------------------
# 완료
# ---------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 준비 완료"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ls -lh "${SCRIPT_DIR}/argocd"*.yaml
echo ""
echo " 다음 단계:"
echo "   ansible-playbook -i hosts.ini phase8_argocd.yml"
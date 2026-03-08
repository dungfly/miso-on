#!/bin/bash
set -euo pipefail

# ===== 수정해서 쓰세요 =====
MASTER1_HOST="${MASTER1_HOST:-10.1.2.10}"     # master1 IP
MASTER1_USER="${MASTER1_USER:-ubuntu}"        # master1 접속 계정
API_ENDPOINT="${API_ENDPOINT:-10.1.1.10}"     # HAProxy VIP
DEST="${DEST:-$HOME/.kube/config}"            # bastion kubeconfig 경로
# ===========================

mkdir -p "$(dirname "$DEST")"
chmod 700 "$(dirname "$DEST")"

echo "==> [1/4] master1에 임시 kubeconfig 생성 (/tmp/admin.conf)"
ssh -o StrictHostKeyChecking=no "${MASTER1_USER}@${MASTER1_HOST}" \
  "sudo cp -f /etc/kubernetes/admin.conf /tmp/admin.conf &&
   sudo chown ${MASTER1_USER}:${MASTER1_USER} /tmp/admin.conf &&
   sudo chmod 600 /tmp/admin.conf"

echo "==> [2/4] bastion으로 복사 -> ${DEST}"
scp -o StrictHostKeyChecking=no "${MASTER1_USER}@${MASTER1_HOST}:/tmp/admin.conf" "${DEST}"

echo "==> [3/4] kubeconfig server를 HAProxy로 고정"
sed -i "s|server: https://.*:6443|server: https://${API_ENDPOINT}:6443|g" "${DEST}"
chmod 600 "${DEST}"

echo "==> [4/4] master1 임시파일 삭제"
ssh -o StrictHostKeyChecking=no "${MASTER1_USER}@${MASTER1_HOST}" \
  "sudo rm -f /tmp/admin.conf" || true

echo "DONE. 테스트:"
echo "  kubectl get nodes -o wide"
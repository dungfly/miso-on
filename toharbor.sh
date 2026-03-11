#!/bin/bash

# 1. 키 권한 설정 (이미 되어 있다면 생략 가능)
chmod 400 miso-key.pem

# 2. 목적지 정보 설정
TARGET="ubuntu@10.1.5.10"
KEY="~/miso-key.pem"

# 3. 파일 전송 (공통 확장자나 목록 활용)
# 여러 파일을 한 줄에 적으면 SSH 연결 한 번에 전송됩니다.
scp -i $KEY \
    tls.crt tls.key ca.crt \
    A1_harbor_install.sh A2_image_collect.sh A5_bastion_pkg_collect.sh A6_gitea_install.sh \
    $TARGET:~/

echo "전송 완료!"
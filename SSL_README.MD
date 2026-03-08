# *.miso.local SSL 인증서 관리

## 인증서 정보
- 방식: 자체서명 와일드카드 인증서 (*.miso.local)
- 유효기간: 10년 (3650일)
- CA: MISO Root CA

## 파일 목록
| 파일 | 용도 | 보관 위치 |
|------|------|-----------|
| ca.crt | Root CA 인증서 - 접속 PC에 설치 | 베스천 + 접속 PC |
| ca.key | Root CA 개인키 - **외부 유출 금지** | 베스천만 보관 |
| tls.crt | 와일드카드 서버 인증서 | 베스천 |
| tls.key | 와일드카드 서버 개인키 | 베스천 |

## 최초 설치 순서
```bash
# 1. 작업 PC에서 인증서 생성
bash 00_gen_certs.sh

# 2. 접속 PC에 CA 설치
# Windows: 00_install_ca_windows.bat (관리자 권한)
# macOS  : bash 00_install_ca_macos.sh

# 3. 베스천에 인증서 복사
scp -i miso-key.pem ca.crt tls.crt tls.key \
  ubuntu@<BASTION_IP>:~/run-bastion/

# 4. SSL 적용
ansible-playbook -i hosts.ini 19_ssl_setup.yml
```

## 인증서 갱신 (10년 후)
```bash
# 1. 기존 인증서 백업
cp ca.crt ca.crt.bak && cp tls.crt tls.crt.bak && cp tls.key tls.key.bak

# 2. 새 인증서 생성
bash 00_gen_certs.sh

# 3. 접속 PC CA 재설치 (CA를 새로 만든 경우)
# Windows: 기존 "MISO Root CA" 삭제 후 00_install_ca_windows.bat 재실행
# macOS  : 기존 "MISO Root CA" 삭제 후 00_install_ca_macos.sh 재실행

# 4. K8s 및 서비스에 적용
ansible-playbook -i hosts.ini 19_ssl_setup.yml
```

## 적용된 서비스
| 서비스 | URL | 인증서 적용 방식 |
|--------|-----|-----------------|
| Harbor | https://harbor.miso.local | Docker 인증서 교체 |
| ArgoCD | https://argocd.miso.local | K8s Ingress TLS |
| Grafana | https://monitor.miso.local | nginx reverse proxy |
| OpenSearch | https://dashboard.miso.local | K8s Ingress TLS |
| MinIO Console | https://s3console.miso.local | K8s Ingress TLS (cert-manager → wildcard 교체) |
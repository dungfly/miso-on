# Harbor 독립 프로세스

Harbor는 폐쇄망 구성의 핵심 인프라입니다.
- 컨테이너 이미지 레지스트리 (HTTPS :443)
- apt 패키지 로컬 저장소 (HTTP :8080/debs/)
- K8s manifest 파일 서버 (HTTP :8080/manifests/)

## 전체 설치 순서

```
[인터넷 환경에서 사전 작업]

1. Harbor 설치
   ansible-playbook -i ../hosts.ini A1_harbor_install.yml

2. 리소스 수집 (Harbor 서버에서 직접 실행)
   bash A2_image_collect.sh
   → 컨테이너 이미지 → Harbor push
   → deb 패키지      → /data/debs/{common|k8s|docker|haproxy}/
   → K8s manifest    → /data/manifests/
   → nginx :8080 서빙 자동 구성

─────────────────────────────────────────────
[폐쇄망 전환 후 메인 설치]

3. 로컬 apt 저장소 등록 (전체 노드)
   ansible-playbook -i ../hosts.ini A4_local_repo_setup.yml

4. ansible-playbook -i hosts.ini phase1_infra_base.yml
5. ansible-playbook -i hosts.ini reboot_all.yml

6. K8s 클러스터 구성
   ansible-playbook -i hosts.ini phase2_k8s_cluster.yml

7. Harbor CA 배포 (phase2 완료 직후 필수)
   ansible-playbook -i ../hosts.ini A3_harbor_ca_distribute.yml

8. ansible-playbook -i hosts.ini phase3_db_nodes.yml
9. ansible-playbook -i hosts.ini phase4_infra_services.yml
10. ansible-playbook -i hosts.ini phase5_data_services.yml
11. ansible-playbook -i hosts.ini phase6_monitoring.yml
12. ansible-playbook -i hosts.ini phase7_operations.yml
13. ansible-playbook -i hosts.ini 99_healthcheck.yml
```

## 수집 항목 (A2)

### 컨테이너 이미지
| 이름 | 원본 | Harbor 경로 |
|------|------|-------------|
| minio | quay.io/minio/minio:latest | harbor.miso.local/miso/minio:latest |
| postgres | ghcr.io/cloudnative-pg/postgresql:16 | harbor.miso.local/miso/postgres:16 |
| cnpg | ghcr.io/cloudnative-pg/cloudnative-pg:1.22.1 | harbor.miso.local/miso/cnpg:1.22.1 |
| redis | redis:7.4.3-alpine | harbor.miso.local/miso/redis:7.4.3-alpine |
| opensearch | opensearchproject/opensearch:2.19.1 | harbor.miso.local/miso/opensearch:2.19.1 |
| opensearch-dashboards | opensearchproject/opensearch-dashboards:2.19.1 | harbor.miso.local/miso/opensearch-dashboards:2.19.1 |
| busybox | busybox:1.36 | harbor.miso.local/miso/busybox:1.36 |

### apt 패키지 그룹
| 그룹 | 패키지 | 대상 노드 |
|------|--------|-----------|
| common | curl jq git vim net-tools htop chrony iptables ca-certificates gnupg openssl ansible | 전체 |
| k8s | containerd kubelet kubeadm kubectl | masters, workers, db_nodes |
| docker | docker-ce docker-ce-cli containerd.io docker-compose-plugin | harbor, monitoring |
| haproxy | haproxy | lb |

### K8s manifest
| 파일 | 용도 |
|------|------|
| tigera-operator.yaml | Calico CNI |
| calico-custom-resources.yaml | Calico 설정 |
| ingress-nginx.yaml | Ingress Controller |
| cert-manager.yaml | 인증서 관리 |
| local-path-storage.yaml | StorageClass |
| cnpg-1.22.1.yaml | CloudNativePG Operator |
| argocd-install.yaml | ArgoCD |
| argocd-image-updater.yaml | ArgoCD Image Updater |

## Bastion 폐쇄망 대응

Bastion은 Harbor가 뜨기 전에 구성되므로 Harbor apt 미러를 사용할 수 없습니다.
폐쇄망 환경에서는 별도 deb 번들을 사전 수집해서 tar.gz에 포함시킵니다.

```
[인터넷 환경에서 1회 실행]
# 1. bastion 패키지 번들 수집
bash harbor_process/A5_bastion_pkg_collect.sh
→ ./bastion-pkgs/ 디렉토리 생성

# 2. tar.gz 으로 압축 (bastion-pkgs/ 포함)
tar -czf run-bastion.tar.gz \
  --exclude='*.zip' \
  --exclude='*.tar.gz' \
  -C "$(dirname $(pwd))" "$(basename $(pwd))"

# 3. 베스천으로 전송 (scp)
scp -i miso-key.pem run-bastion.tar.gz ubuntu@10.1.1.50:~/

[베스천에서]
# 4. 압축 해제 (tar 는 Ubuntu 기본 설치)
tar -xzf run-bastion.tar.gz
cd run-bastion/   # 또는 압축 해제된 디렉토리명

# 5. bastion 초기화 실행
bash 01_prep_bastion.sh
→ bastion-pkgs/ 디렉토리가 있으면 자동으로 오프라인 모드 동작
→ 없으면 인터넷 모드로 동작
```

## 파일 구성

| 파일 | 역할 |
|------|------|
| A1_harbor_install.yml | Harbor 서버 설치 + 프로젝트 생성 |
| A2_image_collect.sh | 이미지/패키지/manifest 수집 + nginx 서빙 구성 |
| A3_harbor_ca_distribute.yml | K8s 노드 CA 배포 + CoreDNS 등록 |
| A4_local_repo_setup.yml | 전체 노드 로컬 apt 저장소 등록 |
| A5_bastion_pkg_collect.sh | Bastion 전용 deb 번들 수집 (오프라인 대비) |
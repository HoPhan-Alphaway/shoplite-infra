# shoplite-infra

Terraform và script dựng hạ tầng GCP của ShopLite (Phase 6). **Mới là bản nháp: chưa `apply`, chưa chạy script nào, chưa tạo gì trên GCP.** Phân tích và lý do thiết kế: `shoplite/learning/phase-6-gke-phan-tich.md`. Phần cấu hình trong cluster nằm ở `shoplite-gitops/clusters/`.

## Hai tầng

| Tầng | Thư mục | Vòng đời | Chứa gì |
|---|---|---|---|
| **Bền** | `gcp/persistent` | Apply một lần, giữ mãi (gần 0 đồng khi nhàn rỗi) | Bucket GCS cho Loki/Tempo, "vỏ" Secret Manager, Google service account (Loki, Tempo, External Secrets) |
| **Tạm** | `gcp/cluster` | `gke-up` khi học, `gke-down` khi xong | VPC, GKE zonal, node pool 2× `n2-standard-4`, các liên kết Workload Identity |

Dữ liệu cần giữ nằm ngoài cluster (Neon Postgres, GCS, Secret Manager, git), nên xoá cluster không mất gì quan trọng.

## Thiết kế theo quota của tài khoản dùng thử

Trần thật (đã đọc bằng `gcloud`): **12 vCPU toàn cầu**, **4 địa chỉ IP đang dùng**, không Spot. Vì vậy: 2 node × 4 vCPU (8 vCPU, 3 IP kể cả Load Balancer), còn chỗ cho một node tạm khi nâng cấp. **Đừng tăng `node_count` hay đổi `machine_type` khi chưa kiểm quota.**

## Script

| Script | Việc |
|---|---|
| `scripts/bootstrap-state.sh` | Một lần: bucket chứa state Terraform |
| `scripts/seed-secrets.sh` | Nạp giá trị secret vào Secret Manager: `generate` (khoá RSA, mật khẩu, client secret), `db` (nhập tay, dự phòng), `cloudflare-token`, `origin-cert`, `status`. Không in giá trị. Đã chạy thử offline với `gcloud` giả |
| `scripts/neon-provision.sh` | Tạo role + database trên Neon cho Keycloak và mọi service trong `services.txt` × dev/prod, ghi thẳng thông tin kết nối vào Secret Manager. Có `--dry-run`, chạy lại được, không in mật khẩu. Đã thử với Neon giả (mock), chưa thử với Neon thật |

`services.txt` là danh sách service duy nhất, cả Terraform tầng bền lẫn `neon-provision.sh` đều đọc. Thêm service mới: thêm một dòng, `terraform apply` ở `gcp/persistent`, rồi chạy `neon-provision.sh`.
| `scripts/gke-up.sh` | Dựng cluster: Terraform → kubectl → Argo CD (helm) → root app. Hỏi trước khi tốn tiền |
| `scripts/gke-down.sh` | Xoá cluster **sau khi dọn PVC, Service LoadBalancer** (xoá cluster không xoá ổ đĩa PVC), rồi `terraform destroy`, rồi liệt kê thứ còn sót |

## Thứ tự làm lần đầu (chưa chạy lần nào)

1. Mua domain, đưa DNS về Cloudflare; tạo Origin Certificate cho `*.<domain>` và API token (Zone.DNS:Edit); tạo project Neon (1 project `shoplite`, region AWS `us-east-2`, chưa cần tạo database) và một API key.
2. `bash scripts/bootstrap-state.sh`, rồi `cp gcp/backend.hcl.example gcp/backend.hcl`.
3. `gcp/persistent`: `terraform init -backend-config=../backend.hcl -backend-config="prefix=persistent"`, `plan`, đọc kỹ, `apply`.
4. `seed-secrets.sh generate`, `cloudflare-token`, `origin-cert <crt> <key>`. Với Neon: `NEON_PROJECT_ID=<id> bash scripts/neon-provision.sh --dry-run`, đọc kết quả, rồi chạy không có `--dry-run` (hỏi API key, ẩn). Cuối cùng `seed-secrets.sh status` không còn `MISSING`.
5. Ở `shoplite-gitops`: `bash scripts/set-domain.sh <domain>`, sửa host Neon của Keycloak, commit, merge vào `main`.
6. `bash scripts/gke-up.sh`. Dùng xong: `bash scripts/gke-down.sh`.

Từ lần sau chỉ cần bước 6.

## Hàm PowerShell gợi ý (thêm vào profile nếu muốn; chưa thêm)

```powershell
function gke-up   { & "C:\Program Files\Git\bin\bash.exe" C:/Users/Dell/Documents/shoplite/shoplite-infra/scripts/gke-up.sh @args }
function gke-down { & "C:\Program Files\Git\bin\bash.exe" C:/Users/Dell/Documents/shoplite/shoplite-infra/scripts/gke-down.sh @args }
```

## Điều cần xác minh ở lần `plan` đầu tiên

Các điểm chưa chắc vì chưa chạy với GCP thật (`terraform validate` chỉ kiểm cú pháp, đã đạt):

- Tắt logging/monitoring của GKE (`logging_service = "none"`, `monitoring_service = "none"`, tắt managed Prometheus) có được chấp nhận cùng khối `monitoring_config` không.
- `remove_default_node_pool` kèm `node_config` nhỏ cho pool mặc định tạm thời.
- Tên ServiceAccount (`loki`, `tempo`, `external-secrets`) trong `variables.tf`: đã đối chiếu với kết quả `helm template`, khớp.
- Quota IP: 2 node + Load Balancer = 3 trong 4; khi nâng cấp node có thêm 1 node tạm là vừa đủ 4.
- Xoá cluster có để lại ổ đĩa hay luật tường lửa của LB không (`gke-down.sh` đã dọn trước và kiểm lại sau).

## Không nằm trong repo này

- Bản ghi DNS: do `external-dns` trong cluster tạo ở Cloudflare.
- Cấu hình ứng dụng trong cluster: `shoplite-gitops/clusters/gke-us/`.
- Ngân sách/cảnh báo chi phí: đã tạo bằng `gcloud` từ trước (không do Terraform quản lý).

# Docker Image Versions

## 2026-08-26
- Installer `v0.3.0` is independent from Daiana application image versions.
- Release bundles present in this repository: `releases/v2.2.0.json`, `releases/v2.4.1.json`, `releases/prod-v2.4.0-studio-mapping.json`, `releases/qa-v2.3.0-studio-v3.1.3.json`, and `releases/shared-message-quota.json`.

## 2026-07-26
- Default pin: cloudseidoranalytics/daianastudio:v3.1.3 (prev cloudseidoranalytics/daianastudio:v3.1.2)
- Official opt-in application bundle `releases/v2.2.0.json`:
  - cloudseidoranalytics/daiana@sha256:9889e14b52230c52f428007ac52e665f695482caa993b2f2271eb7a06e46c173
  - cloudseidoranalytics/daianapython@sha256:fe60febd128657e50ee9cd61bc848d7f05e3faf15cb605977d8c81946a3431b6
  - cloudseidoranalytics/daianastudio@sha256:18a49d2177a8c648cc451043b554df1a66536f2acf268105e76dc0380d0a46a4
- The default Next and Python Compose pins remain at v2.1.9; the application v2.2.0 bundle is selected explicitly and is independent from Installer v0.2.0.

## 2026-07-08
- cloudseidoranalytics/daiana:v2.1.9 (prev cloudseidoranalytics/daiana:v2.1.8)
- cloudseidoranalytics/daianapython:v2.1.9 (prev cloudseidoranalytics/daianapython:v2.1.8)
- cloudseidoranalytics/daianavanna:v2.1.9 (prev cloudseidoranalytics/daianavanna:v2.1.8)
- cloudseidoranalytics/daianamsteams:v2.1.9 (prev cloudseidoranalytics/daianamsteams:v2.1.8)
- cloudseidoranalytics/daianawhatsapp:v2.1.9 (prev cloudseidoranalytics/daianawhatsapp:v2.1.8)
- cloudseidoranalytics/daianawebui:v0.10.2 (prev cloudseidoranalytics/daianawebui:v0.6.30)

## 2026-06-17
- supabase/postgres:17.6.1.136 (prev supabase/postgres:15.8.1.085)

## 2026-06-03
- supabase/studio:2026.06.03-sha-0bca601 (prev supabase/studio:2026.04.27-sha-5f60601)
- supabase/gotrue:v2.189.0 (prev supabase/gotrue:v2.186.0)
- postgrest/postgrest:v14.12 (prev postgrest/postgrest:v14.8)
- supabase/realtime:v2.102.3 (prev supabase/realtime:v2.76.5)
- supabase/storage-api:v1.60.4 (prev supabase/storage-api:v1.48.26)
- supabase/postgres-meta:v0.96.6 (prev supabase/postgres-meta:v0.96.3)
- supabase/edge-runtime:v1.74.0 (prev supabase/edge-runtime:v1.71.2)
- supabase/supavisor:2.9.5 (prev supabase/supavisor:2.7.4)
- supabase/logflare:1.43.1 (prev supabase/logflare:1.36.1)

## 2026-04-27
- supabase/studio:2026.04.27-sha-5f60601 (prev supabase/studio:2026.04.08-sha-205cbe7)

## 2026-04-08
- supabase/studio:2026.04.08-sha-205cbe7 (prev supabase/studio:2026.03.16-sha-5528817)
- postgrest/postgrest:v14.8 (prev postgrest/postgrest:v14.6)
- supabase/storage-api:v1.48.26 (prev supabase/storage-api:v1.44.2)
- supabase/postgres-meta:v0.96.3 (prev supabase/postgres-meta:v0.95.2)
- supabase/logflare:1.36.1 (prev supabase/logflare:1.31.2)

## 2026-03-16
- supabase/studio:2026.03.16-sha-5528817 (prev supabase/studio:2026.02.16-sha-26c615c)
- kong/kong:3.9.1 (prev kong:2.8.1)
- postgrest/postgrest:v14.6 (prev postgrest/postgrest:v14.5)
- supabase/storage-api:v1.44.2 (prev supabase/storage-api:v1.37.8)
- supabase/edge-runtime:v1.71.2 (prev supabase/edge-runtime:v1.70.3)

## 2026-02-16
- supabase/studio:2026.02.16-sha-26c615c (prev supabase/studio:2026.01.27-sha-6aa59ff)
- supabase/gotrue:v2.186.0 (prev supabase/gotrue:v2.185.0)
- postgrest/postgrest:v14.5 (prev postgrest/postgrest:v14.3)
- supabase/realtime:v2.76.5 (prev supabase/realtime:v2.72.0)
- supabase/storage-api:v1.37.8 (prev supabase/storage-api:v1.37.1)
- supabase/edge-runtime:v1.70.3 (prev supabase/edge-runtime:v1.70.0)
- supabase/logflare:1.31.2 (prev supabase/logflare:1.30.3)
- timberio/vector:0.53.0-alpine (prev timberio/vector:0.28.1-alpine)

## 2026-02-05
- supabase/storage-api:v1.37.1 (prev supabase/storage-api:v1.33.5)

## 2026-01-27
- supabase/studio:2026.01.27-sha-6aa59ff (prev supabase/studio:2025.12.17-sha-43f4f7f)
- supabase/gotrue:v2.185.0 (prev supabase/gotrue:v2.184.0)
- postgrest/postgrest:v14.3 (prev postgrest/postgrest:v14.1)
- supabase/realtime:v2.72.0 (prev supabase/realtime:v2.68.0)
- supabase/storage-api:v1.33.5 (prev supabase/storage-api:v1.33.0)
- darthsim/imgproxy:v3.30.1 (prev darthsim/imgproxy:v3.8.0)
- supabase/postgres-meta:v0.95.2 (prev supabase/postgres-meta:v0.95.1)
- supabase/edge-runtime:v1.70.0 (prev supabase/edge-runtime:v1.69.28)
- supabase/logflare:1.30.3 (prev supabase/logflare:1.27.0)

## 2025-12-18
- supabase/studio:2025.12.17-sha-43f4f7f (prev supabase/studio:2025.12.09-sha-434634f)
- supabase/gotrue:v2.184.0 (prev supabase/gotrue:v2.183.0)
- supabase/postgres-meta:v0.95.1 (prev supabase/postgres-meta:v0.93.1)
- supabase/logflare:1.27.0 (prev supabase/logflare:1.26.25)

## 2025-12-10
- supabase/studio:2025.12.09-sha-434634f (prev supabase/studio:2025.11.26-sha-8f096b5)
- postgrest/postgrest:v14.1 (prev postgrest/postgrest:v13.0.7)
- supabase/realtime:v2.68.0 (prev supabase/realtime:v2.65.3)
- supabase/storage-api:v1.33.0 (prev supabase/storage-api:v1.32.0)
- supabase/edge-runtime:v1.69.28 (prev supabase/edge-runtime:v1.69.25)
- supabase/logflare:1.26.25 (prev supabase/logflare:1.26.13)

## 2025-11-26
- supabase/studio:2025.11.26-sha-8f096b5 (prev supabase/studio:2025.11.24-sha-d990ae8)
- supabase/realtime:v2.65.3 (prev supabase/realtime:v2.65.2)
- supabase/logflare:1.26.13 (prev supabase/logflare:1.26.12)

## 2025-11-25
- supabase/studio:2025.11.24-sha-d990ae8 (prev supabase/studio:2025.11.10-sha-5291fe3)
- supabase/gotrue:v2.183.0 (prev supabase/gotrue:v2.182.1)
- supabase/realtime:v2.65.2 (prev supabase/realtime:v2.63.0)
- supabase/storage-api:v1.32.0 (prev supabase/storage-api:v1.29.0)
- supabase/edge-runtime:v1.69.25 (prev supabase/edge-runtime:v1.69.23)
- supabase/logflare:1.26.12 (prev supabase/logflare:1.22.6)

## 2025-11-12
- supabase/studio:2025.11.10-sha-5291fe3 (prev supabase/studio:2025.10.27-sha-85b84e0)
- supabase/gotrue:v2.182.1 (prev supabase/gotrue:v2.180.0)
- supabase/realtime:v2.63.0 (prev supabase/realtime:v2.57.2)
- supabase/storage-api:v1.29.0 (prev supabase/storage-api:v1.28.2)
- supabase/edge-runtime:v1.69.23 (prev supabase/edge-runtime:v1.69.15)
- supabase/supavisor:2.7.4 (prev supabase/supavisor:2.7.3)

## 2025-10-28
- supabase/studio:2025.10.27-sha-85b84e0 (prev supabase/studio:2025.10.20-sha-5005fc6)
- supabase/realtime:v2.57.2 (prev supabase/realtime:v2.56.0)
- supabase/storage-api:v1.28.2 (prev supabase/storage-api:v1.28.1)
- supabase/postgres-meta:v0.93.1 (prev supabase/postgres-meta:v0.93.0)
- supabase/edge-runtime:v1.69.15 (prev supabase/edge-runtime:v1.69.14)

## 2025-10-21
- supabase/studio:2025.10.20-sha-5005fc6 (prev supabase/studio:2025.10.01-sha-8460121)
- supabase/realtime:v2.56.0 (prev supabase/realtime:v2.51.11)
- supabase/storage-api:v1.28.1 (prev supabase/storage-api:v1.28.0)
- supabase/postgres-meta:v0.93.0 (prev supabase/postgres-meta:v0.91.6)
- supabase/edge-runtime:v1.69.14 (prev supabase/edge-runtime:v1.69.6)
- supabase/supavisor:2.7.3 (prev supabase/supavisor:2.7.0)

## 2025-10-13
- supabase/logflare:1.22.6 (prev supabase/logflare:1.22.4)

## 2025-10-08
- supabase/studio:2025.10.01-sha-8460121 (prev supabase/studio:2025.06.30-sha-6f5982d)
- supabase/gotrue:v2.180.0 (prev supabase/gotrue:v2.177.0)
- postgrest/postgrest:v13.0.7 (prev postgrest/postgrest:v12.2.12)
- supabase/realtime:v2.51.11 (prev supabase/realtime:v2.34.47)
- supabase/storage-api:v1.28.0 (prev supabase/storage-api:v1.25.7)
- supabase/postgres-meta:v0.91.6 (prev supabase/postgres-meta:v0.91.0)
- supabase/logflare:1.22.4 (prev supabase/logflare:1.14.2)
- supabase/postgres:15.8.1.085 (prev supabase/postgres:15.8.1.060)
- supabase/supavisor:2.7.0 (prev supabase/supavisor:2.5.7)

## 2025-07-15
- supabase/gotrue:v2.177.0 (prev supabase/gotrue:v2.176.1)
- supabase/storage-api:v1.25.7 (prev supabase/storage-api:v1.24.7)
- supabase/postgres-meta:v0.91.0 (prev supabase/postgres-meta:v0.89.3)
- supabase/supavisor:2.5.7 (prev supabase/supavisor:2.5.6)

## 2025-07-02
- supabase/studio:2025.06.30-sha-6f5982d (prev supabase/studio:2025.06.02-sha-8f2993d)
- supabase/gotrue:v2.176.1 (prev supabase/gotrue:v2.174.0)
- supabase/storage-api:v1.24.7 (prev supabase/storage-api:v1.23.0)
- supabase/supavisor:2.5.6 (prev supabase/supavisor:2.5.1)

## 2025-06-03
- supabase/studio:2025.06.02-sha-8f2993d (prev supabase/studio:2025.05.19-sha-3487831)
- supabase/gotrue:v2.174.0 (prev supabase/gotrue:v2.172.1)
- supabase/storage-api:v1.23.0 (prev supabase/storage-api:v1.22.17)
- supabase/postgres-meta:v0.89.3 (prev supabase/postgres-meta:v0.89.0)

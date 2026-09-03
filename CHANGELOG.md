# Changelog

All notable changes to the Supabase self-hosted Docker configuration.

Changes are grouped by service rather than by change type. See [versions.md](./versions.md) for complete image version history and rollback information.

See per-service updates below for details. Only the most important changes relevant to [self-hosted Supabase](https://supabase.com/docs/guides/self-hosting) are included here. For the full list of changes, refer to the release notes and changelogs of each individual service.

**Note:** Configuration updates marked with "requires [...] update" are already included in the latest version of the repository. Pull the latest changes or refer to the linked PR for manual updates. After updating `docker-compose.yml`, pull the latest images and recreate containers - use `docker compose pull && docker compose down && docker compose up -d`.

---

## Unreleased

---

⚠️ **Upcoming changes:**
- ⚠️ **Breaking change** (week of July 6, 2026): Access to the OpenAPI spec at `/rest/v1/` via the anon (publishable) key will be removed. Requests using the service role or new secret keys are unaffected, and data access via `/rest/v1/your_table` or any client library continues to work as it does today. See discussion [#42949](https://github.com/orgs/supabase/discussions/42949).
- ⚠️ **Breaking change** (week of July 6, 2026): `API_EXTERNAL_URL` will be updated to include the `/auth/v1` path prefix (e.g. `http://localhost:8000/auth/v1`), aligning self-hosted with the platform and CLI. This makes custom OAuth providers work out of the box and moves SAML SSO endpoints to `/auth/v1/sso/saml/*`. See discussion [#47093](https://github.com/orgs/supabase/discussions/47093).

## [0.4.1](https://github.com/SeidorA/daianainstaller/compare/daiana-installer-v0.4.0...daiana-installer-v0.4.1) (2026-09-03)


### Bug Fixes

* **installer:** generate provisioning secret and pin releases ([836858c](https://github.com/SeidorA/daianainstaller/commit/836858c68e97c0bd04754bafaa47d3ac9cf77785))

## [0.4.0](https://github.com/SeidorA/daianainstaller/compare/daiana-installer-v0.3.2...daiana-installer-v0.4.0) (2026-09-03)


### Features

* **db:** add tracked Daiana database migrations ([01c8be9](https://github.com/SeidorA/daianainstaller/commit/01c8be94c1cb6f83eb77fe328a1af6420841dacc))
* **db:** add tracked Daiana migrations ([2d04356](https://github.com/SeidorA/daianainstaller/commit/2d043564d64e94753afdbf36ee742763fe186eb5))
* **db:** add vault secret bootstrap ([d129773](https://github.com/SeidorA/daianainstaller/commit/d129773207b33abc41c192e10f7c1650859cf472))
* **db:** catalog Studio mapping resources ([c98bc1c](https://github.com/SeidorA/daianainstaller/commit/c98bc1c25772875887ec0cd8b318489aa300623c))
* **db:** refresh init SQL assets ([23ebfc6](https://github.com/SeidorA/daianainstaller/commit/23ebfc67917f124728d312542d12101967666a70))
* deploy four-service QA candidate bundles ([cb6fd36](https://github.com/SeidorA/daianainstaller/commit/cb6fd364b3b36a31644ea79707fce2bf129c54ea))
* **deploy:** add digest-bound application bundles ([1dbcb20](https://github.com/SeidorA/daianainstaller/commit/1dbcb20ce3e80671da78dfe0604f8f1170739e4a))
* **deploy:** add digest-bound application bundles ([af6f3b0](https://github.com/SeidorA/daianainstaller/commit/af6f3b0f1a4971868a9731a88d43a37814a98323))
* **deploy:** require complete digest bundles ([4486de6](https://github.com/SeidorA/daianainstaller/commit/4486de6d9f2f78b221e89e3f526fd074cc62a63b))
* **deploy:** support selectable Daiana update versions ([4c33be1](https://github.com/SeidorA/daianainstaller/commit/4c33be1d8f380dd1a2f6ed79de8d5ea6fe0430ab))
* **harness:** verify Teams service authentication ([#22](https://github.com/SeidorA/daianainstaller/issues/22)) ([9bfc864](https://github.com/SeidorA/daianainstaller/commit/9bfc86471a865c047838904e693f79a24fd71824))
* **installer:** add certificate lifecycle management ([1e07fbf](https://github.com/SeidorA/daianainstaller/commit/1e07fbf6960b9b83919e8d22036033632b756ec8))
* **installer:** expose npm and portainer secrets ([0985148](https://github.com/SeidorA/daianainstaller/commit/098514837eb87faf8f64d7a917cb54069e70da8c))
* **installer:** refine bootstrap and Daiana seed flow ([767d005](https://github.com/SeidorA/daianainstaller/commit/767d0057c4bcf01b6fd6461b83da12ee6dde3325))
* **installer:** support local Studio provisioning ([#55](https://github.com/SeidorA/daianainstaller/issues/55)) ([#56](https://github.com/SeidorA/daianainstaller/issues/56)) ([613f4ce](https://github.com/SeidorA/daianainstaller/commit/613f4cecac0dd467963d43f83e53d905547792d6))
* **migrations:** add legacy daianastudio profile ([05f4f17](https://github.com/SeidorA/daianainstaller/commit/05f4f17fd36438ebdc8b598e1289eb57d85e5c83))
* **migrations:** add legacy daianastudio profile ([bf5dfe6](https://github.com/SeidorA/daianainstaller/commit/bf5dfe67df7ee6d1efeab11c284cd008bc6cdc4c))
* **migrations:** add manual dmo compatibility package ([d410377](https://github.com/SeidorA/daianainstaller/commit/d410377854485132c59778226c366d3e8a9e1332))
* **migrations:** add manual DMO compatibility package ([88138a5](https://github.com/SeidorA/daianainstaller/commit/88138a57cced81b752dee6e22f3a6d3af9b6bfd0))
* **migrations:** update daianastudio image and add shared message quota replay migration ([5d5accf](https://github.com/SeidorA/daianainstaller/commit/5d5accf860cb322ee20648628a1902cd957f1b61))
* **private-chat:** add local candidate harness and migration safeguards ([#16](https://github.com/SeidorA/daianainstaller/issues/16)) ([95bcf05](https://github.com/SeidorA/daianainstaller/commit/95bcf05a2661139759a002cc58189b11f3667ba7))
* **release:** add official v2.2.0 deployment bundle ([0c33f29](https://github.com/SeidorA/daianainstaller/commit/0c33f296b99417977557e9af79f1de4b11e7aef3))
* **release:** add shared message quota bundle ([281bec9](https://github.com/SeidorA/daianainstaller/commit/281bec94e1e91441a64063e376bdba3798ed3235))
* **release:** add shared message quota bundle ([f811a87](https://github.com/SeidorA/daianainstaller/commit/f811a87b8e305edb57f4f818f41a486861a0c35e))
* **release:** promote four-service QA bundle support ([4590583](https://github.com/SeidorA/daianainstaller/commit/4590583eca4c1bbbeabe2d69b6ef37ccde00a80f))
* **release:** promote four-service QA bundle support ([bf59e40](https://github.com/SeidorA/daianainstaller/commit/bf59e40199582d537aedb052fa1d7c021436b846))
* **release:** promote Installer v0.2.0 bundle ([d10a697](https://github.com/SeidorA/daianainstaller/commit/d10a6971570fa8e3ddcead5ae743ac2b3d04c4a5))
* support four-service QA candidate bundles ([2f0b2cf](https://github.com/SeidorA/daianainstaller/commit/2f0b2cfa9bb1f319d3bd8c86019a604c1bde48a6))
* **update:** add rollback snapshots and repo sync guard ([c594ad3](https://github.com/SeidorA/daianainstaller/commit/c594ad3aa5327ae3b45f6c876f95eac7352fa440))


### Bug Fixes

* **.gitignore:** update environment variable patterns to include all .env files except example ([5c51db9](https://github.com/SeidorA/daianainstaller/commit/5c51db9dbd685058e5a303f6c0a7e6200f3ae192))
* **ci:** accept lightweight release tags ([0c9b8b0](https://github.com/SeidorA/daianainstaller/commit/0c9b8b0470fcb4905cd433249a3f0b66d1434221))
* **ci:** accept lightweight release tags ([df12c09](https://github.com/SeidorA/daianainstaller/commit/df12c09e7375b0154f6d4aa2a8e2c466a2a49f3b))
* **ci:** authenticate stable release bootstrap ([a1190ee](https://github.com/SeidorA/daianainstaller/commit/a1190ee7621af63ea8d1c4f40f266edf83782ef0))
* **ci:** authenticate stable release bootstrap ([57a9b34](https://github.com/SeidorA/daianainstaller/commit/57a9b345d4aebefb0664fe9972b77b2ca9fc1bbb))
* **ci:** authenticate stable release registry reads ([7753418](https://github.com/SeidorA/daianainstaller/commit/77534186fa1edd2883773a5fb56cb909aa276221))
* **ci:** authenticate stable release registry reads ([a80caa9](https://github.com/SeidorA/daianainstaller/commit/a80caa9a11fa29f79b2e2792ff6aa69c2284c99e))
* **ci:** detect new stable release bundles ([3fe6c3e](https://github.com/SeidorA/daianainstaller/commit/3fe6c3e992f83c154fbf9e62bd1313183b994359))
* **ci:** detect new stable release bundles ([a8d3205](https://github.com/SeidorA/daianainstaller/commit/a8d3205810b87bad0740c0c268101a5a29af5cb2))
* **ci:** read Front release metadata ([2d4250e](https://github.com/SeidorA/daianainstaller/commit/2d4250e2e03e0b6aa0fde3679977df63678a5b5b))
* **ci:** read Front release metadata ([8b6622e](https://github.com/SeidorA/daianainstaller/commit/8b6622e927736d2ed13c01298273d32e684fde14))
* **ci:** support indented compose service pins ([b9c9133](https://github.com/SeidorA/daianainstaller/commit/b9c91337d6a9bfaefc060a67306f9d8e269cf69f))
* **ci:** support indented compose service pins ([e60b49d](https://github.com/SeidorA/daianainstaller/commit/e60b49d34ad71f88dac4feb374e721698480a14b))
* **compose:** pin Studio to v3.1.3 ([5ad9b78](https://github.com/SeidorA/daianainstaller/commit/5ad9b7891698ae41f4ad9c79443967cbdb259f34))
* **db:** cast Studio catalog names ([81b662a](https://github.com/SeidorA/daianainstaller/commit/81b662a73694186a83b46cda79d9d113c1569a55))
* **db:** provision tenant runtime secrets ([21387f7](https://github.com/SeidorA/daianainstaller/commit/21387f7ffdc3385d1a55f6f739ec88cbf39ca3a7))
* **db:** provision tenant runtime secrets ([9f9820b](https://github.com/SeidorA/daianainstaller/commit/9f9820b7771c5545fd87b7358538436bf6abf492))
* **db:** reset license seed sequences dynamically ([bd9185d](https://github.com/SeidorA/daianainstaller/commit/bd9185d6002f3fdf82bec89d9f1c51dcb9b9f1d9))
* **db:** support manual Studio schema ([d09cd0a](https://github.com/SeidorA/daianainstaller/commit/d09cd0a03ff2cb81f43a4a277c2961421b5b11a8))
* **deploy:** align Daiana URLs and version targets ([9151ccc](https://github.com/SeidorA/daianainstaller/commit/9151ccc7e5fc06aa040994d6e59a05ee1966aabd))
* **deploy:** preserve Portainer environment on rollback ([4b807eb](https://github.com/SeidorA/daianainstaller/commit/4b807eb98b075bb28358f8c633bb6313c5d80c5e))
* **installer:** accept NPM proxy response metadata ([f0fe87d](https://github.com/SeidorA/daianainstaller/commit/f0fe87dab26fda82e7e503a91c2e4cc5831849be))
* **installer:** add docker group access ([a66d9e1](https://github.com/SeidorA/daianainstaller/commit/a66d9e1ba7f13e09e5266c313bf6de67a90795b2))
* **installer:** add private registry auth ([1355a35](https://github.com/SeidorA/daianainstaller/commit/1355a35312dd7569eb1003d4a5fb8d3b7b65019d))
* **installer:** adjust tenant auth defaults ([5fb3114](https://github.com/SeidorA/daianainstaller/commit/5fb31145771e26f81339d0ded2580fc44cdd5ad1))
* **installer:** align local runtime with v2.4.1 ([9f79cf2](https://github.com/SeidorA/daianainstaller/commit/9f79cf255e9aa0efd597153addca8413d99befe7))
* **installer:** align private chat and Teams environment variables ([#14](https://github.com/SeidorA/daianainstaller/issues/14)) ([238d116](https://github.com/SeidorA/daianainstaller/commit/238d116126232e2f6e8208eeee65beb8cb8c0c3a))
* **installer:** align URL schemes with certificate lifecycle ([e01ce76](https://github.com/SeidorA/daianainstaller/commit/e01ce769511fdf6e5b20ff2b8542a6bd1d9afbba))
* **installer:** align vault seed vars ([4ff175f](https://github.com/SeidorA/daianainstaller/commit/4ff175fc249eb691b4fff2d82493a32b5c1264e5))
* **installer:** auto-install docker prerequisites ([6b1ca4c](https://github.com/SeidorA/daianainstaller/commit/6b1ca4cb70895399e4fc7806261fca546e8b556c))
* **installer:** clarify docker group refresh ([ba57a4f](https://github.com/SeidorA/daianainstaller/commit/ba57a4f5249ffeab20d61212643c5b344ea63b06))
* **installer:** document daiana app env vars ([b8b0da9](https://github.com/SeidorA/daianainstaller/commit/b8b0da9c9ed7d4ca76e47967b23b95fcbb3b0db2))
* **installer:** harden TLS credentials and deployment recovery ([#18](https://github.com/SeidorA/daianainstaller/issues/18)) ([5a8d1b3](https://github.com/SeidorA/daianainstaller/commit/5a8d1b319331fcc623144ebe998f3a2581db0535))
* **installer:** pre-pull private daiana images ([2099d41](https://github.com/SeidorA/daianainstaller/commit/2099d412901ce9b8a6f85105009cc1966424bd1a))
* **installer:** preserve auth migration history ([1bda38d](https://github.com/SeidorA/daianainstaller/commit/1bda38d5902f95c41256cf9ac62d854d53e86009))
* **installer:** preserve auth migration history ([3dbe9c3](https://github.com/SeidorA/daianainstaller/commit/3dbe9c39cf91e72faa754dfd39c935e79e883342))
* **installer:** preserve omitted bundle services ([b288e3c](https://github.com/SeidorA/daianainstaller/commit/b288e3cfdaf19daaab2285076524edd0fbd681ab))
* **installer:** preserve omitted bundle services ([7d2fbb4](https://github.com/SeidorA/daianainstaller/commit/7d2fbb45385a6d7a3ea31ca35d5c2bea32c76728))
* **installer:** refresh cert env and msteams host ([6bc513e](https://github.com/SeidorA/daianainstaller/commit/6bc513eefa929a9d787fbebd1c83f364b4cf85a5))
* **installer:** resolve shellcheck findings ([c640af5](https://github.com/SeidorA/daianainstaller/commit/c640af5ad37193e12c6d5348c90838a2c89791ad))
* **installer:** restore legacy NPM TLS compatibility ([579fe9b](https://github.com/SeidorA/daianainstaller/commit/579fe9bf25e9e3cb2ffebf9d638f11f2d312c20a))
* **installer:** satisfy shellcheck for dynamic exports ([ce6fa84](https://github.com/SeidorA/daianainstaller/commit/ce6fa84f86363a98f411c27b0d399c10ebf7f7e9))
* **installer:** secure daiana auth handoff seed ([5d59571](https://github.com/SeidorA/daianainstaller/commit/5d595718d666910557e95623b5a3d9fcc2b71e85))
* **installer:** stabilize QA bundle deployment ([fb45fa1](https://github.com/SeidorA/daianainstaller/commit/fb45fa10b065315ddfb14359ea2751765afc24fe))
* **installer:** support macos app storage ([78ed977](https://github.com/SeidorA/daianainstaller/commit/78ed97715f14fd281c75531df7daf14d4ccd92b1))
* **installer:** update npm letsencrypt payload ([0e2520e](https://github.com/SeidorA/daianainstaller/commit/0e2520e0783f8a6c4eedcce9261fdc405ad76494))
* **installer:** wait for auth migrations before seeds ([7f637ed](https://github.com/SeidorA/daianainstaller/commit/7f637ed9cbdc9961b28d17a787d579e5459bef08))
* **installer:** warn on stale docker session ([65d1913](https://github.com/SeidorA/daianainstaller/commit/65d1913ec0ccd77197f09db21be47ac338842052))
* **make:** preserve rollback snapshots during wipe ([7d65ddd](https://github.com/SeidorA/daianainstaller/commit/7d65ddd19d3d4d6266333575a8c076b36132ff5d))
* **migrations:** restrict replay quota RPC access ([9cf9085](https://github.com/SeidorA/daianainstaller/commit/9cf9085a6ddba23904260a574b82297704867284))
* **migrations:** restrict replay quota RPC access ([52468b5](https://github.com/SeidorA/daianainstaller/commit/52468b57ce3a6b42f710d6643d9ee80227e87710))
* **portainer:** isolate nested request traps ([c7b6902](https://github.com/SeidorA/daianainstaller/commit/c7b690254144d3c8522a6c2fd28f28fec0b0517f))
* **portainer:** isolate nested request traps ([b511618](https://github.com/SeidorA/daianainstaller/commit/b5116180e61fb144362822181b394f05dd3f1af2))
* **portainer:** isolate nested stack traps ([47efc0a](https://github.com/SeidorA/daianainstaller/commit/47efc0aa8eed23fc03cbe5784bc92ba19ce6393d))
* **portainer:** isolate nested stack traps ([d0ea8d7](https://github.com/SeidorA/daianainstaller/commit/d0ea8d7b2aafd98bf6feb186dd357dd63068d5ba))
* **release:** verify deployment and replay contracts ([8313db9](https://github.com/SeidorA/daianainstaller/commit/8313db9346656b181e31380bcbee3db0a540576c))
* **webui:** allow configured site and webui CORS origins ([6f49f80](https://github.com/SeidorA/daianainstaller/commit/6f49f80d6f24066cd7453a42e0962500119797d0))

## v0.3.2 - 2026-09-01

### WebUI
- Updated the WebUI image from `v0.10.2` to `v0.11.1`.

## v0.3.1 - 2026-08-27

### WebUI
- Fixed the WebUI/Socket.IO CORS origin allow-list to accept both `${SITE_URL}` and `${WEBUI_BASE_URL}`. This is backward-compatible.

## v0.3.0 - 2026-08-26

### Daiana installer
- Added candidate and complete-stack deployment bundles with immutable-reference validation and fail-closed deployment checks.
- Hardened certificate and proxy-host lifecycle handling, deployment recovery, and rollback snapshots.
- Added forward-only, checksum-tracked database migrations and the manual DMO compatibility package.
- Added Studio mapping catalog support and legacy Daiana Studio profile and schema compatibility.
- Improved local macOS installer behavior and TLS compatibility.
- Added stable-release automation for release metadata and installer pin updates.
- Fixed compatibility with NPM proxy response metadata.
- Expanded integration, lifecycle, migration, bundle, macOS, and release-automation tests and updated operator documentation.

Check the main Supabase [changelog](https://github.com/orgs/supabase/discussions/categories/changelog?discussions_q=is%3Aopen+category%3AChangelog+label%3Aself-hosted) for updates.

---

## [v0.1.0](https://github.com/SeidorA/daianainstaller/releases/tag/v0.1.0) - 2026-07-08

### Daiana installer
- Added the Bash installer flow for bootstrapping Portainer, Nginx Proxy Manager, Supabase, Daiana services, and post-start database seeds.
- Added private Docker registry authentication and image pre-pulls before Daiana stack deployment.
- Added waits and guards around Docker access, Supabase Auth migrations, and seed execution, including preservation of Auth migration history.
- Added macOS-compatible application storage handling and documented installation and runtime environment configuration.
- Added formal repository version metadata with `VERSION`.
- Added selectable Daiana image versions during `update`, including optional independently versioned images.
- Added update rollback snapshots under `volumes/daiana/update-history/<timestamp>/` and `update-daiana.sh --rollback`.
- Added repository sync guard before update/rollback, with explicit approval before `git pull --ff-only`.
- Updated Docker Hub registry defaults to `dockerhub-prod-sdr` with URL `docker.io`, while preserving legacy registry compatibility.
- Bumped Daiana app images to `v2.1.9` and WebUI to `v0.10.2`.

**Historical boundary:** annotated tag `v0.1.0` points to commit `adbe14e611af0f6b34ff06fe664a877176954a16` (tree `0bb6f7f726813b3663ea961c0136c0c7272bb934`). Documentation clarification (`abc1a3b`), snapshot-preserving wipe behavior (`7d65ddd`), and dynamic license seed sequence reset (`bd9185d`) were post-v0.1.0 corrections first included in v0.2.0.

---

## [0.6.0](https://github.com/supabase/supabase/releases/tag/self-hosted/v0.6.0) - 2026-06-17

⚠️ **Note:** This update contains **breaking changes**. Make sure to read the **important** details below:
- **Postgres 17 is now the default**. Do not start Postgres 17 on an existing Postgres 15 data directory. See the [Upgrade to Postgres 17](https://supabase.com/docs/guides/self-hosting/postgres-upgrade-17) guide. Check the **Configuration** and **Postgres** sections for additional information
- API gateway configuration includes a **security fix** for Realtime routes - it is **strongly recommended** to add this update to any self-hosted Supabase instance running Realtime
- Studio and Postgres Meta configuration now use `postgres` and not `supabase_admin` to connect to Postgres

### Configuration
- ⚠️ Changed the default Postgres image to `supabase/postgres:17.6.1.136` - PR [#46981](https://github.com/supabase/supabase/pull/46981)
- ⚠️ Added `docker-compose.pg15.yml` - for deployments not yet upgraded, and as the rollback target for `utils/upgrade-pg17.sh` - PR [#46981](https://github.com/supabase/supabase/pull/46981)
- Updated `docker-compose.pg17.yml` to match the new default - PR [#46981](https://github.com/supabase/supabase/pull/46981)

### Documentation
- Updated the [Upgrade to Postgres 17](https://supabase.com/docs/guides/self-hosting/postgres-upgrade-17) how-to - PR [#46989](https://github.com/supabase/supabase/pull/46989)
- Updated the [New API Keys](https://supabase.com/docs/guides/self-hosting/self-hosted-auth-keys) and [Envoy API Gateway](https://supabase.com/docs/guides/self-hosting/self-hosted-envoy) how-to guides - PR [#46856](https://github.com/supabase/supabase/pull/46856)
- Updated [CONFIG.md](CONFIG.md) - PR [#47022](https://github.com/supabase/supabase/pull/47022)

### Utils and tests
- Updated `utils/upgrade-pg17.sh` (bumped Postgres image, added additional migrations), and `tests/test-pg17-upgrade.sh` (added tests for pg_cron) - PR [#46981](https://github.com/supabase/supabase/pull/46981)
- Updated `tests/test-self-hosted.sh` (added tests for resumable upload, modified tests for Realtime and GraphQL) - PR [#46731](https://github.com/supabase/supabase/pull/46731), PR [#46856](https://github.com/supabase/supabase/pull/46856), PR [#46981](https://github.com/supabase/supabase/pull/46981)
- Updated `tests/test-auth-keys.sh` (modified tests for Realtime) - PR [#46856](https://github.com/supabase/supabase/pull/46856)

### API gateway
- ⚠️ Updated Kong and Envoy configuration to block access to Realtime `/api/tenants` and `/api/openapi` endpoints. This is a **security fix** (requires `volumes/api/kong.yml` and `volumes/api/envoy` update) - PR [#46856](https://github.com/supabase/supabase/pull/46856)
- Updated entrypoint for Kong to use `/bin/sh` (requires `docker-compose.yml` update) - PR [#46873](https://github.com/supabase/supabase/pull/46873)

### Studio
- ⚠️ Updated `studio` configuration to use `postgres` instead of `supabase_admin` to connect to Postgres (requires `docker-compose.yml` update). See discussion [#46081](https://github.com/orgs/supabase/discussions/46081) and the [how-to guide](https://supabase.com/docs/guides/self-hosting/remove-superuser-access) for important information - PR [#47022](https://github.com/supabase/supabase/pull/47022)

### PostgREST
- Added healthcheck for `rest` (requires `docker-compose.yml` update) - PR [#46658](https://github.com/supabase/supabase/pull/46658)

### Postgres Meta
- ⚠️ Updated `meta` configuration to use `postgres` instead of `supabase_admin` to connect to Postgres (requires `docker-compose.yml` update) - PR [#47022](https://github.com/supabase/supabase/pull/47022)

### Edge Runtime
- Added healthcheck for `functions` (requires `docker-compose.yml` update) - PR [#46655](https://github.com/supabase/supabase/pull/46655)

### Postgres
- ⚠️ Updated the default image to `17.6.1.136` (from `15.8.1.085`). `pg_graphql` is now **disabled by default** on fresh installs. Databases that already use GraphQL keep it after an upgrade. See discussion [#46080](https://github.com/orgs/supabase/discussions/46080) and the [how-to guide](https://supabase.com/docs/guides/self-hosting/postgres-upgrade-17) for more information - PR [#46981](https://github.com/supabase/supabase/pull/46981)

---

## [0.5.0](https://github.com/supabase/supabase/releases/tag/self-hosted/v0.5.0) - 2026-06-03

⚠️ **Note:** This update includes **important changes**. Please check the details below.

### Configuration
- ⚠️ Logs and analytics are now [optional](https://github.com/orgs/supabase/discussions/46084) and were removed from the default `docker-compose.yml`. A new `docker-compose.logs.yml` override has been added. Check the main [configuration guide](https://supabase.com/docs/guides/self-hosting/docker#enabling-analytics) and the changes to Studio below for more information - PR [#45327](https://github.com/supabase/supabase/pull/45327) (via [@luizfelmach](https://github.com/luizfelmach/))
- ⚠️ Added `COMPOSE_FILE` to `.env.example` for configuring compose overrides (also used by `run.sh`) - PR [#45603](https://github.com/supabase/supabase/pull/45603)

### Documentation
- Added a new [reference list](https://github.com/supabase/supabase/blob/master/docker/CONFIG.md) of all configuration environment variables - PR [#46124](https://github.com/supabase/supabase/pull/46124)
- Updated the main installation and configuration [guide](https://supabase.com/docs/guides/self-hosting/docker) (added "quick start" path and opt-in for logs and analytics; removed the legacy JWT secrets generator) - PR [#46416](https://github.com/supabase/supabase/pull/46416), PR [#45359](https://github.com/supabase/supabase/pull/45359)
- Updated the logs and analytics [how-to guide](https://supabase.com/docs/reference/self-hosting-analytics/introduction) - PR [#46452](https://github.com/supabase/supabase/pull/46452)

### Utils
- Added `setup.sh` and `run.sh` to support quick start and easier management of the compose configuration - PR [#45603](https://github.com/supabase/supabase/pull/45603)
- Updated `utils/add-new-auth-keys.sh` and `utils/rotate-new-api-key.sh` to remove the dependency on OpenSSL and Node.js - PR [#45941](https://github.com/supabase/supabase/pull/45941)
- Updated `tests/test-container-logs.sh` to skip checks for `kong`, `analytics` and `vector` when the services are not running - PR [#46099](https://github.com/supabase/supabase/pull/46099)

### API gateway
- Updated Envoy version to `1.38.0` (see `docker-compose.envoy.yml`) - PR [#46023](https://github.com/supabase/supabase/pull/46023)
- Updated Envoy configuration to address a discrepancy in API key checking (requires `volumes/api/envoy` update) - PR [#46023](https://github.com/supabase/supabase/pull/46023)

### Studio
- Updated to `2026.06.03-sha-0bca601`
- ⚠️ Added `ENABLED_FEATURES_LOGS_ALL` to Studio service configuration (requires `docker-compose.yml` update) - PR [#45327](https://github.com/supabase/supabase/pull/45327)
- ⚠️ Added `SUPABASE_PUBLISHABLE_KEY` and `SUPABASE_SECRET_KEY` to Studio service configuration (requires `docker-compose.yml` update) - PR [#46173](https://github.com/supabase/supabase/pull/46173)
- ⚠️ Added `start_period` to Studio healthcheck for more reliable cold-boot on slower hosts (requires `docker-compose.yml` update) - PR [#45327](https://github.com/supabase/supabase/pull/45327)
- Fixed incorrect connection strings in the connect sheet for self-hosted environments - PR [#46217](https://github.com/supabase/supabase/pull/46217)
- Updated project home and functions page, and added a minimal project settings implementation - PR [#46544](https://github.com/supabase/supabase/pull/46544), PR [#46550](https://github.com/supabase/supabase/pull/46550), PR [#46554](https://github.com/supabase/supabase/pull/46554)

### Auth
- Updated to `v2.189.0` - [Changelog](https://github.com/supabase/auth/blob/master/CHANGELOG.md) | [Release](https://github.com/supabase/auth/releases/tag/v2.189.0)
- ⚠️ Added `GOTRUE_JWT_ISSUER` to Auth service configuration (requires `docker-compose.yml` update) - PR [#46020](https://github.com/supabase/supabase/pull/46020)

### PostgREST
- Updated to `v14.12` - [Changelog](https://github.com/PostgREST/postgrest/blob/main/CHANGELOG.md) | [Release](https://github.com/PostgREST/postgrest/releases/tag/v14.12)

### Realtime
- Updated to `v2.102.3` - [Release](https://github.com/supabase/realtime/releases/tag/v2.102.3)

### Storage
- Updated to `v1.60.4` - [Release](https://github.com/supabase/storage/releases/tag/v1.60.4)

### Postgres Meta
- Updated to `v0.96.6` - [Release](https://github.com/supabase/postgres-meta/releases/tag/v0.96.6)

### Edge Runtime
- Updated to `v1.74.0` - [Release](https://github.com/supabase/edge-runtime/releases/tag/v1.74.0)

### Supavisor
- Updated to `2.9.5` - [Release](https://github.com/supabase/supavisor/releases/tag/v2.9.5)
- Added `POSTGRES_HOST` to Supavisor service configuration (requires `docker-compose.yml` and `volumes/pooler/pooler.exs` update) - PR [#41273](https://github.com/supabase/supabase/pull/41273)

### Analytics (Logflare)
- Updated to `1.43.1` - [Release](https://github.com/Logflare/logflare/releases/tag/v1.43.1)
- ⚠️ Changed default `docker-compose.yml` to no longer include logs & analytics. Read more in Supabase's [changelog](https://github.com/orgs/supabase/discussions/46084) - PR [#45327](https://github.com/supabase/supabase/pull/45327)

---

## 2026-04-27

### Configuration
- ⚠️ Added `docker-compose.envoy.yml` and `volumes/api/envoy`. See also the API gateway updates below - PR [#43838](https://github.com/supabase/supabase/pull/43838)
- ⚠️ Changed Studio healthcheck and some other configuration for better compatibility with Podman (requires `docker-compose.yml` update) - PR [#44754](https://github.com/supabase/supabase/pull/44754)
- ⚠️ Changed Studio configuration to bind to all IPv4 interfaces only (requires `docker-compose.yml` update) - PR [#44772](https://github.com/supabase/supabase/pull/44772)

### Documentation
- Added a new [how-to](https://supabase.com/docs/guides/self-hosting/remove-superuser-access) describing how to switch from `supabase_admin` to `postgres` role for Studio - PR [#42975](https://github.com/supabase/supabase/pull/42975) (via [@singh-inder](https://github.com/singh-inder/))
- Added a new [how-to](https://github.com/supabase/supabase/pull/45152) for configuring Envoy as the new API gateway - PR [#45152](https://github.com/supabase/supabase/pull/45152)
- Updated the main [setup guide](https://supabase.com/docs/guides/self-hosting/docker) and the how-tos to reflect the state of the self-hosted Supabase configuration - PR [#45011](https://github.com/supabase/supabase/pull/45011)

### Utils
- ⚠️ Added `utils/reassign-owner.sh` to update database objects. Read more in the "[Remove superuser access](https://supabase.com/docs/guides/self-hosting/remove-superuser-access)" how-to guide - PR [#42975](https://github.com/supabase/supabase/pull/42975)
- ⚠️ Changed `utils/add-new-auth-keys.sh` to also update `docker-compose.yml` - PR [#45056](https://github.com/supabase/supabase/pull/45056)

### API gateway
- ⚠️ Added Envoy as the new optional API gateway (requires `docker-compose.envoy.yml`, `volumes/api/envoy`, and `volumes/logs/vector.yml` update) - PR [#43838](https://github.com/supabase/supabase/pull/43838) (via [@luizfelmach](https://github.com/luizfelmach/))

### Studio
- Updated to `2026.04.27-sha-5f60601`
- ⚠️ Added 4 new lints to the Security Advisor. Read more about lint rules 0026 - 0029 in the [Performance and Security Advisors](https://supabase.com/docs/guides/database/database-advisors?queryGroups=lint&lint=0026_pg_graphql_anon_table_exposed) section of the Supabase documentation - PR [#45253](https://github.com/supabase/supabase/pull/45253), PR [#45260](https://github.com/supabase/supabase/pull/45260)
---

## 2026-04-08

### Documentation
- Added new how-to guides for configuring [custom email templates](https://supabase.com/docs/guides/self-hosting/custom-email-templates), setting up [SAML SSO](https://supabase.com/docs/guides/self-hosting/self-hosted-saml-sso), and [using Postgres 17](https://supabase.com/docs/guides/self-hosting/postgres-upgrade-17) - PR [#42832](https://github.com/supabase/supabase/pull/42832), PR [#43386](https://github.com/supabase/supabase/pull/43386), PR [#44147](https://github.com/supabase/supabase/pull/44147)

### Utils
- ⚠️ Added `utils/upgrade-pg17.sh`. Read more in the "[Upgrade to Postgres 17](https://supabase.com/docs/guides/self-hosting/postgres-upgrade-17)" how-to guide - PR [#44147](https://github.com/supabase/supabase/pull/44147)

### API gateway
- ⚠️ Added configuration for SAML SSO (requires `.env`, `docker-compose.yml` and `volumes/api/kong.yml` update) - PR [#43385](https://github.com/supabase/supabase/pull/43385) (via [@luizfelmach](https://github.com/luizfelmach/))

### Studio
- Updated to `2026.04.08-sha-205cbe7`

### PostgREST
- Updated to `v14.8` - [Changelog](https://github.com/PostgREST/postgrest/blob/main/CHANGELOG.md) | [Release](https://github.com/PostgREST/postgrest/releases/tag/v14.8)

### Storage
- Updated to `v1.48.26` - [Release](https://github.com/supabase/storage/releases/tag/v1.48.26)

### imgproxy
- Changed `IMGPROXY_ENABLE_WEBP_DETECTION` environment variable to `IMGPROXY_AUTO_WEBP` (requires `.env` and `docker-compose.yml` update) - PR [#43919](https://github.com/supabase/supabase/pull/43919)

### Postgres Meta
- Updated to `v0.96.3` - [Release](https://github.com/supabase/postgres-meta/releases/tag/v0.96.3)

### Analytics (Logflare)
- Updated to `1.36.1` - [Release](https://github.com/Logflare/logflare/releases/tag/v1.36.1)

### Postgres
- ⚠️ Added `docker-compose.pg17.yml` override - PR [#44147](https://github.com/supabase/supabase/pull/44147)
- ⚠️ Added `utils/upgrade-pg17.sh` - PR [#44147](https://github.com/supabase/supabase/pull/44147)
- ⚠️ Added [documentation](https://supabase.com/docs/guides/self-hosting/postgres-upgrade-17) explaining the upgrade to Postgres 17

---

## 2026-03-16

⚠️ **Note:** This update includes **important changes**. Please check the details below. The following configuration files have been added/updated: `utils/add-new-auth-keys.sh`, `utils/rotate-new-api-keys.sh`, `docker-compose.yml`, `.env.example`, `docker-compose.s3.yml`, `docker-compose.rustfs.yml`, `volumes/api/kong.yml`, `volumes/api/kong-entrypoint.sh`, `docker-compose.caddy.yml`, `docker-compose.nginx.yml`, `volumes/functions/main/index.ts`, and `volumes/proxy`.

### Configuration
- ⚠️ Added scripts and templates to support the new API key format (`sb_` API keys) and the new asymmetric authentication. Check the [how-to guide](https://supabase.com/docs/guides/self-hosting/self-hosted-auth-keys) for detailed instructions - PR [#43554](https://github.com/supabase/supabase/pull/43554)
- Added optional proxy configuration for Caddy and nginx. Read the [how-to guide](https://supabase.com/docs/guides/self-hosting/self-hosted-proxy-https) to learn more - PR [#43291](https://github.com/supabase/supabase/pull/43291)

### Documentation
- Added several new how-to guides to the self-hosted Supabase [documentation](https://supabase.com/docs/guides/self-hosting) - PR [#42745](https://github.com/supabase/supabase/pull/42745), PR [#42953](https://github.com/supabase/supabase/pull/42953), PR [#43177](https://github.com/supabase/supabase/pull/43177), PR [#43286](https://github.com/supabase/supabase/pull/43286), PR [#43293](https://github.com/supabase/supabase/pull/43293)

### Utils and tests
- Added `utils/add-new-auth-keys.sh` and `utils/rotate-new-api-keys.sh` - PR [#43554](https://github.com/supabase/supabase/pull/43554)
- Added `tests/` with 100+ test cases - PR [#43573](https://github.com/supabase/supabase/pull/43573)

### Studio
- Updated to `2026.03.16-sha-5528817`
- ⚠️ Added the link to the Data API page in Integrations - PR [#43268](https://github.com/supabase/supabase/pull/43268)
- ⚠️ Added `PGRST_DB_SCHEMAS`, `PGRST_DB_EXTRA_SEARCH_PATH`, and `PGRST_DB_MAX_ROWS` to Studio configuration (requires `docker-compose.yml` update) - PR [#43268](https://github.com/supabase/supabase/pull/43268)

### MCP Server
- Updated to `v0.7.0` - [Release](https://github.com/supabase/mcp/releases/tag/v0.7.0)

### API gateway
- ⚠️ Updated Kong to `3.9.1` - PR [#43554](https://github.com/supabase/supabase/pull/43554)

### PostgREST
- Updated to `v14.6` - [Changelog](https://github.com/PostgREST/postgrest/blob/main/CHANGELOG.md) | [Release](https://github.com/PostgREST/postgrest/releases/tag/v14.6)

### Realtime
- ⚠️ Added **mandatory** `METRICS_JWT_SECRET` environment variable (requires `docker-compose.s3.yml` update) - PR [realtime#1729](https://github.com/supabase/realtime/pull/1729)

### Storage
- Updated to `v1.44.2` - [Release](https://github.com/supabase/storage/releases/tag/v1.44.2)
- ⚠️ Added `STORAGE_PUBLIC_URL` environment variable to simplify proxy configuration (requires `docker-compose.s3.yml` update) - PR [storage#900](https://github.com/supabase/storage/pull/900)
- ⚠️ Added RustFS as an optional S3 backend - PR [#42935](https://github.com/supabase/supabase/pull/42935)
- ⚠️ Changed Docker Compose configuration for S3 backends to use named volumes - PR [#43815](https://github.com/supabase/supabase/pull/43815)

### Edge Runtime
- Updated to `v1.71.2` - [Release](https://github.com/supabase/edge-runtime/releases/tag/v1.71.2)
- ⚠️ Added `SUPABASE_PUBLISHABLE_KEYS`, `SUPABASE_SECRET_KEYS`, and `SUPABASE_PUBLIC_URL` environment variables (requires `docker-compose.yml` update)
- ⚠️ Added an option for a "hybrid" JWT verification following the addition of the new API keys and the new asymmetric authentication (requires `volumes/functions/main/index.ts` update) - PR [#42130](https://github.com/supabase/supabase/pull/42130)
- ⚠️ Added optional rate limiter - PR [edge-runtime#670](https://github.com/supabase/edge-runtime/pull/670)

---

## 2026-02-18

### Storage
- Changed MinIO image to use Chainguard [minio](https://images.chainguard.dev/directory/image/minio/overview) and [minio-client](https://images.chainguard.dev/directory/image/minio-client/overview) (requires `docker-compose.s3.yml` update) - PR [#42942](https://github.com/supabase/supabase/pull/42942)
- Updated Storage image version to `v1.37.8` in `docker-compose.s3.yml`
- Removed `imgproxy` service from `docker-compose.s3.yml` to minimize redundancy - PR [#42942](https://github.com/supabase/supabase/pull/42942)
- Fixed inconsistent `storage` service entry ordering in `docker-compose.yml` and `docker-compose.s3.yml` to improve diff readability - PR [#42942](https://github.com/supabase/supabase/pull/42942)

### Edge Runtime
- Added a `deno-cache` named volume to avoid re-downloading dependencies (requires `docker-compose.yml` and `volumes/functions/*` update) - PR [#40822](https://github.com/supabase/supabase/pull/40822)

---

## 2026-02-16

⚠️ **Note:** This update includes several breaking changes, including a security fix for Analytics. Please check the details below. The following configuration files have been updated: `docker-compose.yml`, `.env.example`, `docker-compose.s3.yml`, `volumes/api/kong.yml`, and `volumes/logs/vector.yml`.

### Studio
- Updated to `2026.02.16-sha-26c615c`
- Added Edge Functions management UI (requires `docker-compose.yml` update) - PR [#40690](https://github.com/supabase/supabase/pull/40690), PR [#42322](https://github.com/supabase/supabase/pull/42322), PR [#42349](https://github.com/supabase/supabase/pull/42349), PR [#42350](https://github.com/supabase/supabase/pull/42350)

### MCP Server
- Updated to `v0.6.3` - [Release](https://github.com/supabase/mcp/releases/tag/v0.6.3)

### Auth
- Updated to `v2.186.0` - [Changelog](https://github.com/supabase/auth/blob/master/CHANGELOG.md) | [Release](https://github.com/supabase/auth/releases/tag/v2.186.0)

### PostgREST
- Updated to `v14.5` - [Changelog](https://github.com/PostgREST/postgrest/blob/main/CHANGELOG.md) | [Release](https://github.com/PostgREST/postgrest/releases/tag/v14.5)

### Realtime
- Updated to `v2.76.5` - [Release](https://github.com/supabase/realtime/releases/tag/v2.76.5)

### Storage
- Updated to `v1.37.8` - [Release](https://github.com/supabase/storage/releases/tag/v1.37.8)
- ⚠️ Changed environment variable configuration for Storage (requires `docker-compose.yml`, `.env.example` and `.env` update) - PR [#37185](https://github.com/supabase/supabase/pull/37185), PR [#42862](https://github.com/supabase/supabase/pull/42862)
- ⚠️ Added **default** configuration to access buckets via `/storage/v1/s3` endpoint (requires `docker-compose.yml` and `.env` update) - PR [#37185](https://github.com/supabase/supabase/pull/37185)
- ⚠️ Changed MinIO configuration for the S3 backend (requires `docker-compose.s3.yml` and `.env` update) - PR [#37185](https://github.com/supabase/supabase/pull/37185)

### Edge Runtime
- Updated to `v1.70.3` - [Release](https://github.com/supabase/edge-runtime/releases/tag/v1.70.3)

### Analytics (Logflare)
- Updated to `1.31.2` - [Release](https://github.com/Logflare/logflare/releases/tag/v1.31.2)
- ⚠️ Changed default configuration to disable Logflare on `0.0.0.0:4000` to prevent access to `/dashboard` (requires `docker-compose.yml` update). Read more in the "Production Recommendations" section of Logflare [documentation](https://supabase.com/docs/reference/self-hosting-analytics/introduction) - PR [#42857](https://github.com/supabase/supabase/pull/42857)
- ⚠️ Changed Kong routes to not include `/analytics/v1` by default (requires `/volumes/api/kong.yml` update) - PR [#42857](https://github.com/supabase/supabase/pull/42857)

### Vector
- Updated to `0.53.0-alpine` - [Changelog](https://vector.dev/releases/0.53.0/) | [Release](https://github.com/vectordotdev/vector/releases/tag/v0.53.0)
- ⚠️ Major version jump from `0.28.1` (requires `volumes/logs/vector.yml` update) - PR [#42525](https://github.com/supabase/supabase/pull/42525)
- ⚠️ Changed Postgres sink configuration to bypass Kong (requires `volumes/logs/vector.yml` update) - PR [#42857](https://github.com/supabase/supabase/pull/42857)
- ⚠️ Changed retry settings for all sinks to increase timeouts (requires `volumes/logs/vector.yml` update) - PR [#42857](https://github.com/supabase/supabase/pull/42857)

---

## 2026-02-05

### Storage
- Updated to `v1.37.1` - [Release](https://github.com/supabase/storage/releases/tag/v1.37.1)
- Fixed an issue with Storage not starting because of an issue with migrations - PR [storage#845](https://github.com/supabase/storage/pull/845)

---

## 2026-01-27

### Studio
- Updated to `2026.01.27-sha-6aa59ff`
- Added SQL snippets (requires `docker-compose.yml` update) - PR [#41112](https://github.com/supabase/supabase/pull/41112), PR [#41557](https://github.com/supabase/supabase/pull/41557), discussion [#42031](https://github.com/orgs/supabase/discussions/42031)
- Fixed type generator - PR [#40481](https://github.com/supabase/supabase/pull/40481)
- Fixed minor UI discrepancies - PR [#40579](https://github.com/supabase/supabase/pull/40579), PR [#41936](https://github.com/supabase/supabase/pull/41936), PR [#41970](https://github.com/supabase/supabase/pull/41970), PR [#41971](https://github.com/supabase/supabase/pull/41971), PR [#41972](https://github.com/supabase/supabase/pull/41972), PR [#42015](https://github.com/supabase/supabase/pull/42015)

### Auth
- Updated to `v2.185.0` - [Changelog](https://github.com/supabase/auth/blob/master/CHANGELOG.md) | [Release](https://github.com/supabase/auth/releases/tag/v2.185.0)
- ⚠️ Fixed security-related issues

### PostgREST
- Updated to `v14.3` - [Changelog](https://github.com/PostgREST/postgrest/blob/main/CHANGELOG.md) | [Release](https://github.com/PostgREST/postgrest/releases/tag/v14.3)

### Realtime
- Updated to `v2.72.0` - [Release](https://github.com/supabase/realtime/releases/tag/v2.72.0)
- Changed healthchecks logging to off by default (requires `docker-compose.yml` update) - PR [realtime#1677](https://github.com/supabase/realtime/pull/1677), PR [#42156](https://github.com/supabase/supabase/pull/42156)
- Changed logging configuration and healthcheck frequency to reduce log volume (requires `docker-compose.yml` update) - PR [#42112](https://github.com/supabase/supabase/pull/42112)

### Storage
- Updated to `v1.33.5` - [Release](https://github.com/supabase/storage/releases/tag/v1.33.5)

### imgproxy
- Updated to `v3.30.1` - [Changelog](https://github.com/imgproxy/imgproxy/blob/master/CHANGELOG.md) | [Release](https://github.com/imgproxy/imgproxy/releases/tag/v3.30.1)

### Postgres Meta
- Updated to `v0.95.2` - [Release](https://github.com/supabase/postgres-meta/releases/tag/v0.95.2)

### Edge Runtime
- Updated to `v1.70.0` - [Release](https://github.com/supabase/edge-runtime/releases/tag/v1.70.0)

### Analytics (Logflare)
- Updated to `1.30.3` - [Release](https://github.com/Logflare/logflare/releases/tag/v1.30.3)

### Postgres
- No image update
- Fixed Postgres logging configuration (requires `volumes/logs/vector.yml` update) - PR [#41800](https://github.com/supabase/supabase/pull/41800)

---

## 2025-12-18

### Documentation
- Updated self-hosting installation and configuration guide - PR [#40901](https://github.com/supabase/supabase/pull/40901), PR [#41438](https://github.com/supabase/supabase/pull/41438)

### Utils
- Added `utils/generate-keys.sh` - PR [#41363](https://github.com/supabase/supabase/pull/41363)
- Added `utils/db-passwd.sh` - PR [#41432](https://github.com/supabase/supabase/pull/41432)
- Changed `reset.sh` to POSIX and added more checks - PR [#41361](https://github.com/supabase/supabase/pull/41361)

### Studio
- Updated to `2025.12.17-sha-43f4f7f`
- ⚠️ Fixed additional issues related to [React2Shell](https://vercel.com/kb/bulletin/react2shell)
- Fixed an issue with the Users page not being updated on changes - PR [#41254](https://github.com/supabase/supabase/pull/41254)

### MCP Server
- Updated to `v0.5.10` - [Release](https://github.com/supabase/mcp/releases/tag/v0.5.10)

### Auth
- Updated to `v2.184.0` - [Changelog](https://github.com/supabase/auth/blob/master/CHANGELOG.md) | [Release](https://github.com/supabase/auth/releases/tag/v2.184.0)

### Postgres Meta
- Updated to `v0.95.1` - [Release](https://github.com/supabase/postgres-meta/releases/tag/v0.95.1)

### Analytics (Logflare)
- Updated to `1.27.0` - [Release](https://github.com/Logflare/logflare/releases/tag/v1.27.0)
- Fixed multiple issues, including a race condition

---

## 2025-12-10

### Studio
- Updated to `2025.12.09-sha-434634f`
- ⚠️ Fixed security issues related to [React2Shell](https://vercel.com/kb/bulletin/react2shell)

### MCP Server
- Updated to `v0.5.9` - [Release](https://github.com/supabase/mcp/releases/tag/v0.5.9)
- ⚠️ Changed MCP tool `get_anon_key` to `get_publishable_keys`

### PostgREST
- Updated to `v14.1` - [Changelog](https://github.com/PostgREST/postgrest/blob/main/CHANGELOG.md) | [Release](https://github.com/PostgREST/postgrest/releases/tag/v14.1)
- ⚠️ **Major upgrade from v13.x to v14.x** - please report any unexpected behavior

### Realtime
- Updated to `v2.68.0` - [Release](https://github.com/supabase/realtime/releases/tag/v2.68.0)

### Storage
- Updated to `v1.33.0` - [Release](https://github.com/supabase/storage/releases/tag/v1.33.0)

### Edge Runtime
- Updated to `v1.69.28` - [Release](https://github.com/supabase/edge-runtime/releases/tag/v1.69.28)

### Analytics (Logflare)
- Updated to `1.26.25` - [Release](https://github.com/Logflare/logflare/releases/tag/v1.26.25)

---

## 2025-12-08

### Realtime
- No image update
- Changed boolean values to strings in Docker Compose for better compatibility with Podman - PR [#40994](https://github.com/supabase/supabase/pull/40994), also PR [realtime#1614](https://github.com/supabase/realtime/pull/1614)
- Changed healthcheck in Docker Compose for better compatibility with Podman - PR [#41159](https://github.com/supabase/supabase/pull/41159)

---

## 2025-11-26

### Studio
- Updated to `2025.11.26-sha-8f096b5`
- Fixed MCP `get_advisors` tool - PR [#40783](https://github.com/supabase/supabase/pull/40783)
- Fixed AI Assistant request schema - PR [#40830](https://github.com/supabase/supabase/pull/40830)
- Fixed log drains page - PR [#40835](https://github.com/supabase/supabase/pull/40835)

### Realtime
- Updated to `v2.65.3` - [Release](https://github.com/supabase/realtime/releases/tag/v2.65.3)

### Analytics (Logflare)
- Updated to `1.26.13` - [Release](https://github.com/Logflare/logflare/releases/tag/v1.26.13)
- Fixed crashdump when `POSTGRES_BACKEND_URL` is malformed - PR [logflare#2954](https://github.com/Logflare/logflare/pull/2954)

---

## 2025-11-25

### Studio
- Updated to `2025.11.24-sha-d990ae8` - [Dashboard updates](https://github.com/orgs/supabase/discussions/40734)
- Fixed Queues configuration UI and added [documentation for exposed queue schema](https://supabase.com/docs/guides/queues/expose-self-hosted-queues) - PR [#40078](https://github.com/supabase/supabase/pull/40078)
- Fixed parameterized SQL queries in MCP tools - PR [#40499](https://github.com/supabase/supabase/pull/40499)
- Fixed Studio showing paid options for log drains - PR [#40510](https://github.com/supabase/supabase/pull/40510)
- Fixed AI Assistant authentication - PR [#40654](https://github.com/supabase/supabase/pull/40654)

### Auth
- Updated to `v2.183.0` - [Changelog](https://github.com/supabase/auth/blob/master/CHANGELOG.md) | [Release](https://github.com/supabase/auth/releases/tag/v2.183.0)

### Realtime
- Updated to `v2.65.2` - [Release](https://github.com/supabase/realtime/releases/tag/v2.65.2)
- Fixed handling of boolean configuration options - PR [realtime#1614](https://github.com/supabase/realtime/pull/1614)

### Storage
- Updated to `v1.32.0` - [Release](https://github.com/supabase/storage/releases/tag/v1.32.0)

### Edge Runtime
- Updated to `v1.69.25` - [Release](https://github.com/supabase/edge-runtime/releases/tag/v1.69.25)

### Analytics (Logflare)
- Updated to `1.26.12` - [Release](https://github.com/Logflare/logflare/releases/tag/v1.26.12)
- Fixed Auth logs query - PR [logflare#2936](https://github.com/Logflare/logflare/pull/2936)
- Fixed build configuration to prevent crashes with "Illegal instruction (core dumped)" - PR [logflare#2942](https://github.com/Logflare/logflare/pull/2942)

---

## 2025-11-17

### Storage
- No image update
- Fixed resumable uploads for files larger than 6MB (requires `docker-compose.yml` update) - PR [#40500](https://github.com/supabase/supabase/pull/40500)

---

## 2025-11-12

### Studio
- Updated to `2025.11.10-sha-5291fe3` - [Dashboard updates](https://github.com/orgs/supabase/discussions/40083)
- Added log drains - PR [#28297](https://github.com/supabase/supabase/pull/28297)
- Fixed Studio using `postgres` role instead of `supabase_admin` - PR [#39946](https://github.com/supabase/supabase/pull/39946)

### Auth
- Updated to `v2.182.1` - [Changelog](https://github.com/supabase/auth/blob/master/CHANGELOG.md#21821-2025-11-05) | [Release](https://github.com/supabase/auth/releases/tag/v2.182.1)

### Realtime
- Updated to `v2.63.0` - [Release](https://github.com/supabase/realtime/releases/tag/v2.63.0)

### Storage
- Updated to `v1.29.0` - [Release](https://github.com/supabase/storage/releases/tag/v1.29.0)

### Edge Runtime
- Updated to `v1.69.23` - [Release](https://github.com/supabase/edge-runtime/releases/tag/v1.69.23)

### Supavisor
- Updated to `2.7.4` - [Release](https://github.com/supabase/supavisor/releases/tag/v2.7.4)

---

## 2025-11-05

### Studio
- No image update
- Fixed Studio failing to connect to Postgres with non-default settings (requires `docker-compose.yml` update) - PR [#40169](https://github.com/supabase/supabase/pull/40169)

### Realtime
- No image update
- Fixed realtime logs not showing in Studio (requires `volumes/logs/vector.yml` update) - PR [#39963](https://github.com/supabase/supabase/pull/39963)

---

## 2025-10-28

### Studio
- Updated to `2025.10.27-sha-85b84e0` - [Dashboard updates](https://github.com/orgs/supabase/discussions/40083)
- Fixed broken authentication when uploading files to Storage - PR [#39829](https://github.com/supabase/supabase/pull/39829)

### Realtime
- Updated to `v2.57.2` - [Release](https://github.com/supabase/realtime/releases/tag/v2.57.2)

### Storage
- Updated to `v1.28.2` - [Release](https://github.com/supabase/storage/releases/tag/v1.28.2)

### Postgres Meta
- Updated to `v0.93.1` - [Release](https://github.com/supabase/postgres-meta/releases/tag/v0.93.1)

### Edge Runtime
- Updated to `v1.69.15` - [Release](https://github.com/supabase/edge-runtime/releases/tag/v1.69.15)

---

## 2025-10-27

### Studio
- No image update
- Added Kong configuration for MCP server routes (requires `volumes/api/kong.yml` update) - PR [#39849](https://github.com/supabase/supabase/pull/39849)
- Added [documentation page](https://supabase.com/docs/guides/self-hosting/enable-mcp) for MCP server configuration - PR [#39952](https://github.com/supabase/supabase/pull/39952)

---

## 2025-10-21

### Studio
- Updated to `2025.10.20-sha-5005fc6` - [Dashboard updates](https://github.com/orgs/supabase/discussions/39709)
- Fixed issues with Edge Functions and cron logs not being visible in Studio - PR [#39388](https://github.com/supabase/supabase/pull/39388), PR [#39704](https://github.com/supabase/supabase/pull/39704), PR [#39711](https://github.com/supabase/supabase/pull/39711)

### Realtime
- Updated to `v2.56.0` - [Release](https://github.com/supabase/realtime/releases/tag/v2.56.0)

### Storage
- Updated to `v1.28.1` - [Release](https://github.com/supabase/storage/releases/tag/v1.28.1)

### Postgres Meta
- Updated to `v0.93.0` - [Release](https://github.com/supabase/postgres-meta/releases/tag/v0.93.0)

### Edge Runtime
- Updated to `v1.69.14` - [Release](https://github.com/supabase/edge-runtime/releases/tag/v1.69.14)

### Supavisor
- Updated to `2.7.3` - [Release](https://github.com/supabase/supavisor/releases/tag/v2.7.3)

---

## 2025-10-13

### Analytics (Logflare)
- Updated to `1.22.6` - [Release](https://github.com/Logflare/logflare/releases/tag/v1.22.6)

---

## 2025-10-08

### Studio
- Updated to `2025.10.01-sha-8460121` - [Dashboard updates](https://github.com/orgs/supabase/discussions/39709)
- Added "local" remote MCP server - PR [#38797](https://github.com/supabase/supabase/pull/38797), PR [#39041](https://github.com/supabase/supabase/pull/39041)
- ⚠️ Changed Studio connection method to `postgres-meta` - affects non-standard database port configurations

### Auth
- Updated to `v2.180.0` - [Release](https://github.com/supabase/auth/releases/tag/v2.180.0)

### PostgREST
- Updated to `v13.0.7` - [Release](https://github.com/PostgREST/postgrest/releases/tag/v13.0.7) | [Changelog](https://github.com/PostgREST/postgrest/blob/main/CHANGELOG.md)

### Realtime
- Updated to `v2.51.11` - [Release](https://github.com/supabase/realtime/releases/tag/v2.51.11)

### Storage
- Updated to `v1.28.0` - [Release](https://github.com/supabase/storage/releases/tag/v1.28.0)

### Postgres Meta
- Updated to `v0.91.6` - [Release](https://github.com/supabase/postgres-meta/releases/tag/v0.91.6)

### Analytics (Logflare)
- Updated to `1.22.4` - [Release](https://github.com/Logflare/logflare/releases/tag/v1.22.4)

### Postgres
- Updated to `15.8.1.085` - [Release](https://github.com/supabase/postgres/releases/tag/15.8.1.085)

### Supavisor
- Updated to `2.7.0` - [Release](https://github.com/supabase/supavisor/releases/tag/v2.7.0)

---

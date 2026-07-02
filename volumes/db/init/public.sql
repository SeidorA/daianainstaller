SET session_replication_role = replica;

--
-- PostgreSQL database dump
--

-- \restrict Cw59pJqVDg4JCsda62ds7MnxdlGc8bWltNGOYJABJzSj7jlKsbt2ecg4TdNudhf

-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Data for Name: tenants; Type: TABLE DATA; Schema: public; Owner: supabase_admin
--

INSERT INTO "public"."tenants" ("idTenant", "email", "plan", "payment", "company", "idSubscription", "disclaimer", "createdAt", "updatedUser", "updatedAt", "sincro", "interval", "customerId", "paymentDate", "settings") VALUES
	(1, 'cloud@seidoranalytics.com', 'studio', true, 'SEIDOR Analytics', '00000000-0000-0000-0000-000000000000', false, '2026-06-26 01:23:46.277767', NULL, '2026-07-02 15:45:41.380955', false, NULL, 'internal', '2026-07-02 15:45:41.37597', '{"domain": "seidoranalytics.com", "license": {"mode": "ONLINE_SYNCED", "params": {"maxMessages": 10000, "studioIntegrated": true}, "source": "keyforge", "warning": null, "plan_name": "studio", "expires_at": "2027-05-10T00:00:00+00:00", "total_days": 364, "customer_id": "internal", "product_code": "daiana", "validated_at": "2026-07-02T15:45:41.375970+00:00"}, "created_by": "c5c27317-4fb8-4e0c-be6b-ae9fd6808913", "accessMethods": {"email": true, "sso_google": false}, "additionalOptions": {"register": false, "reset_password": true}, "llmProcessingMode": "cpu"}'::jsonb || jsonb_build_object('secretSeed', gen_random_uuid()::text, 'teamsSecret', 'waHW4b2Kfe_OoYXxnSUscqIMuESvQhunKt6deG1uXyU='));

--
-- Data for Name: teams; Type: TABLE DATA; Schema: public; Owner: supabase_admin
--

INSERT INTO "public"."teams" ("id", "createdAt", "name", "description", "imageUrl", "idTenant", "sincro", "visible") VALUES
	('96d2e992-c4c8-491a-a4bd-e9a687185dec', '2026-06-26 01:23:46.277767+00', 'Default Team', 'Equipo creado automáticamente para el nuevo usuario', NULL, 1, false, true);


--
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: supabase_admin
--

INSERT INTO "public"."users" ("id", "email", "first_name", "last_name", "id_tenantint", "phone", "country", "company", "imgurl", "role", "status", "settings") VALUES
	('c5c27317-4fb8-4e0c-be6b-ae9fd6808913', 'cloud@seidoranalytics.com', 'Cloud', 'Seidor Analytics', 1, '3057055095', 'Colombia', 'SEIDOR Analytics', '', 'admin', true, '{"screen": "/agents"}');


--
-- Data for Name: aibot; Type: TABLE DATA; Schema: public; Owner: supabase_admin
--

INSERT INTO "public"."aibot" ("idBot", "idTenant", "name", "description", "createdUser", "createdAt", "updatedUser", "updatedAt", "disabled", "team", "imageUrl", "type", "messageInitial", "deleted", "botpublic", "settings") VALUES
	(1, 1, 'Daiana Help', 'Asistente AI para ayudarte con tu plataforma', 'c5c27317-4fb8-4e0c-be6b-ae9fd6808913', '2026-06-26 01:23:46.277767', NULL, NULL, false, '96d2e992-c4c8-491a-a4bd-e9a687185dec', NULL, 'document', '¡Hola! Soy Daiana Help, ¿en qué puedo asistirte hoy?', false, false, NULL);


--
-- Data for Name: databases; Type: TABLE DATA; Schema: public; Owner: supabase_admin
--



--
-- Data for Name: document; Type: TABLE DATA; Schema: public; Owner: supabase_admin
--



--
-- Data for Name: documents; Type: TABLE DATA; Schema: public; Owner: supabase_admin
--



--
-- Data for Name: history; Type: TABLE DATA; Schema: public; Owner: supabase_admin
--



--
-- Data for Name: login_sessions; Type: TABLE DATA; Schema: public; Owner: studio
--



--
-- Data for Name: roles; Type: TABLE DATA; Schema: public; Owner: postgres
--

INSERT INTO "public"."roles" ("id", "tenantid", "name", "description", "created_at", "updated_at") VALUES
	('c5869db2-6538-4a3c-8923-abf359176fb6', 1, 'admin', NULL, '2025-07-09 15:05:16.789+00', NULL),
	('1f6420e0-fe91-4a45-9d79-9792189549d9', 1, 'creator', NULL, '2025-07-09 15:05:16.789+00', NULL),
	('91d7813d-be3b-439d-874c-47721c8b9442', 1, 'user', NULL, '2025-07-09 15:05:16.789+00', NULL);


--
-- Data for Name: role_permissions; Type: TABLE DATA; Schema: public; Owner: postgres
--

INSERT INTO "public"."role_permissions" ("id", "role_id", "permission", "created_at", "updated_at") VALUES
	('0669a5d3-9c0a-4e60-9dfe-ea48f0702b94', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'create:dashboard', '2025-07-09 15:06:30.154+00', NULL),
	('d546bf99-2c41-4525-80c1-2550d0af729b', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'read:dashboard', '2025-07-09 15:06:30.154+00', NULL),
	('aa9c4c3b-6e6c-4e08-b8a0-c5bf8a07f01b', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'update:dashboard', '2025-07-09 15:06:30.154+00', NULL),
	('35c70e3d-18b4-4700-9488-050080bfcc34', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'delete:dashboard', '2025-07-09 15:06:30.154+00', NULL),
	('6767c6c2-57e5-4258-92d3-bc9d799f7fe7', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'create:knowledge', '2025-07-09 15:06:30.154+00', NULL),
	('fa99cafc-c5e6-499c-85f0-1fab941922f5', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'read:knowledge', '2025-07-09 15:06:30.154+00', NULL),
	('7202a4a4-a57e-40c8-ad23-a67df0535fbe', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'update:knowledge', '2025-07-09 15:06:30.154+00', NULL),
	('cc21f5da-7392-45c9-aac8-00150dda777d', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'delete:knowledge', '2025-07-09 15:06:30.154+00', NULL),
	('761dc350-661f-4cd1-a0de-435eb3c9353c', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'create:agents', '2025-07-09 15:06:30.154+00', NULL),
	('67690f4d-5404-4515-abfc-62ec1a6bd0ec', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'read:agents', '2025-07-09 15:06:30.154+00', NULL),
	('4b3505e6-88e8-443c-8fa4-db1b592a7119', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'update:agents', '2025-07-09 15:06:30.154+00', NULL),
	('25c5dc6d-c1b7-42ee-9ef4-03d7114e6f0a', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'delete:agents', '2025-07-09 15:06:30.154+00', NULL),
	('1b869aae-dcaa-47df-8376-0e01618dfb96', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'create:management', '2025-07-09 15:06:30.154+00', NULL),
	('febf939c-b229-47ee-b35d-4758251537cb', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'read:management', '2025-07-09 15:06:30.154+00', NULL),
	('18516c0a-1bc6-4e53-a839-f54f5bb4be59', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'update:management', '2025-07-09 15:06:30.154+00', NULL),
	('14594c2a-a6b1-441c-a2ce-3d4bb194c1e3', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'delete:management', '2025-07-09 15:06:30.154+00', NULL),
	('0ab0c9e0-2123-4d17-9c12-e38216f3496f', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'create:history', '2025-07-09 15:06:30.154+00', NULL),
	('5b4c2242-5eda-49eb-a862-ae259611b4d5', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'read:history', '2025-07-09 15:06:30.154+00', NULL),
	('41859b68-b510-4285-9bbb-cd5421a8b646', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'update:history', '2025-07-09 15:06:30.154+00', NULL),
	('179b676c-4171-471d-982f-638acbaf7e80', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'delete:history', '2025-07-09 15:06:30.154+00', NULL),
	('4b67ddb9-538b-4e5f-9811-7e8c9787e624', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'create:expressai', '2025-07-09 15:06:30.154+00', NULL),
	('1c5e1d29-f2a9-4238-ba08-5d900eb8463f', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'read:expressai', '2025-07-09 15:06:30.154+00', NULL),
	('0eae64c7-50f2-497d-9536-4128f4c2a9de', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'update:expressai', '2025-07-09 15:06:30.154+00', NULL),
	('5db3f403-74af-4c54-8132-4a49fe73dddc', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'delete:expressai', '2025-07-09 15:06:30.154+00', NULL),
	('d034c489-d17d-468a-874f-5e4fdf59abe3', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'create:studio', '2025-07-09 15:06:30.154+00', NULL),
	('ba4c0a20-46a7-4fee-9d87-1faa3b5ce479', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'read:studio', '2025-07-09 15:06:30.154+00', NULL),
	('4ccefc4b-f2cc-422a-ac70-2a5cf32055e6', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'update:studio', '2025-07-09 15:06:30.154+00', NULL),
	('b97f08db-4373-4184-9b51-60025d5bd2b8', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'delete:studio', '2025-07-09 15:06:30.154+00', NULL),
	('57ec368e-3b51-414e-8cbc-e0938560ceb1', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'create:profile', '2025-07-09 15:06:30.154+00', NULL),
	('81657011-9a5f-49fe-9b91-9ae2b0bc2d14', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'read:profile', '2025-07-09 15:06:30.154+00', NULL),
	('7a59d42e-cacc-491e-ac49-684441986389', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'update:profile', '2025-07-09 15:06:30.154+00', NULL),
	('d16a8ae1-63c8-42b8-b6a9-246cf0f6a5e8', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'delete:profile', '2025-07-09 15:06:30.154+00', NULL),
	('ae280ca0-5e3a-4fc5-9d64-5b91171461a5', 'c5869db2-6538-4a3c-8923-abf359176fb6', 'read:help', '2025-07-09 15:06:30.154+00', NULL),
	('838daf6a-c1f8-411f-9f0f-213315fa452f', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'create:agents', '2025-07-09 15:06:30.154+00', NULL),
	('fa9e492f-3175-4847-8492-a84ba5092727', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'read:agents', '2025-07-09 15:06:30.154+00', NULL),
	('7f471424-6373-4778-b0d5-df23a3ba00ca', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'update:agents', '2025-07-09 15:06:30.154+00', NULL),
	('5b1f4019-ebd4-414d-b3b6-ce832b1aeb5e', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'delete:agents', '2025-07-09 15:06:30.154+00', NULL),
	('9d70993d-066b-4809-895b-b071017c0ee0', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'create:history', '2025-07-09 15:06:30.154+00', NULL),
	('7d2335ca-993f-43fa-94f4-5a0da0ac6419', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'read:history', '2025-07-09 15:06:30.154+00', NULL),
	('fbb9a626-c059-43c1-bbec-4dc565e489d7', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'update:history', '2025-07-09 15:06:30.154+00', NULL),
	('b4542db5-6014-40f3-af4b-0e91b98c0db1', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'delete:history', '2025-07-09 15:06:30.154+00', NULL),
	('48ff584b-6fe0-4c00-a2a3-d78cd21b8708', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'create:expressai', '2025-07-09 15:06:30.154+00', NULL),
	('1d2fbc7a-32bf-4000-9bec-3d8ea4ed5292', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'read:expressai', '2025-07-09 15:06:30.154+00', NULL),
	('1364984a-ce9a-40ae-a3c4-37ab49ff9059', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'update:expressai', '2025-07-09 15:06:30.154+00', NULL),
	('13df062b-0fa8-47fc-9ddd-6285be249c1a', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'delete:expressai', '2025-07-09 15:06:30.154+00', NULL),
	('074d5416-a634-4b1b-9ae3-93b3a1e17bc5', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'create:studio', '2025-07-09 15:06:30.154+00', NULL),
	('66e3167f-476c-474a-a0ea-f7956308626b', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'read:studio', '2025-07-09 15:06:30.154+00', NULL),
	('c319f387-230b-4106-9709-ae7316f6a262', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'update:studio', '2025-07-09 15:06:30.154+00', NULL),
	('9eb9e7c8-b1f3-4a46-9474-0f66b3ac41ed', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'delete:studio', '2025-07-09 15:06:30.154+00', NULL),
	('1d2f01c1-2d62-4a14-8239-a1c14e2b0d5b', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'create:profile', '2025-07-09 15:06:30.154+00', NULL),
	('485be025-3adc-477e-94d0-941c166be99b', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'read:profile', '2025-07-09 15:06:30.154+00', NULL),
	('c2f11696-99ec-42e5-9c50-54fdbd9689aa', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'update:profile', '2025-07-09 15:06:30.154+00', NULL),
	('13dd3748-64f2-4d8c-8748-81c1f7e89568', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'delete:profile', '2025-07-09 15:06:30.154+00', NULL),
	('a9b88e1b-ae1c-49be-8f3f-789f09e91c7c', '1f6420e0-fe91-4a45-9d79-9792189549d9', 'read:help', '2025-07-09 15:06:30.154+00', NULL),
	('6e990771-c8b6-4024-adc5-30aa8acad113', '91d7813d-be3b-439d-874c-47721c8b9442', 'create:agents', '2025-07-09 15:06:30.154+00', NULL),
	('8bca2794-f3ea-4483-8e9c-edb95ac68fd2', '91d7813d-be3b-439d-874c-47721c8b9442', 'read:agents', '2025-07-09 15:06:30.154+00', NULL),
	('f114b37a-9de2-47f0-90fe-c968acc9a98d', '91d7813d-be3b-439d-874c-47721c8b9442', 'update:agents', '2025-07-09 15:06:30.154+00', NULL),
	('153d113e-dca4-4bde-8f60-fda8fa307d83', '91d7813d-be3b-439d-874c-47721c8b9442', 'delete:agents', '2025-07-09 15:06:30.154+00', NULL),
	('04df0c02-a6dd-4469-bcf5-0ecf32ee42aa', '91d7813d-be3b-439d-874c-47721c8b9442', 'create:profile', '2025-07-09 15:06:30.154+00', NULL),
	('2f7efbe3-6a1e-4ee5-9150-b0638aea7ef4', '91d7813d-be3b-439d-874c-47721c8b9442', 'read:profile', '2025-07-09 15:06:30.154+00', NULL),
	('a23d48e5-597e-4328-904d-71e3ad3b8edb', '91d7813d-be3b-439d-874c-47721c8b9442', 'update:profile', '2025-07-09 15:06:30.154+00', NULL),
	('df1cec18-8d0a-4e36-afa3-5e261f96aafd', '91d7813d-be3b-439d-874c-47721c8b9442', 'delete:profile', '2025-07-09 15:06:30.154+00', NULL),
	('d100fed8-da2e-4bf8-b511-28f9e0fe6007', '91d7813d-be3b-439d-874c-47721c8b9442', 'read:help', '2025-07-09 15:06:30.154+00', NULL);


--
-- Data for Name: teamsecurityuser; Type: TABLE DATA; Schema: public; Owner: postgres
--

INSERT INTO "public"."teamsecurityuser" ("id", "created_at", "team", "user", "tenant", "role", "member") VALUES
	('e6c2fd94-38f7-4682-b422-1d634b473087', '2026-06-26 01:23:46.277767+00', '96d2e992-c4c8-491a-a4bd-e9a687185dec', 'c5c27317-4fb8-4e0c-be6b-ae9fd6808913', 1, 'admin', true);


--
-- Data for Name: tenant_license_activation_attempts; Type: TABLE DATA; Schema: public; Owner: postgres
--

INSERT INTO "public"."tenant_license_activation_attempts" ("id", "idTenant", "rawPayload", "licenseBundle", "activationRequest", "activationResponse", "httpStatus", "errorCode", "errorMessage", "status", "uploadedFilename", "createdAt", "updatedAt") VALUES
	(1, 1, '{}', '{}', '{}', '{"mode": "ONLINE_SYNCED", "params": {"maxMessages": 10000, "studioIntegrated": true}, "source": "keyforge", "warning": null, "plan_name": "studio", "expires_at": "2027-05-10T00:00:00Z", "total_days": 364, "customer_id": "internal", "product_code": "daiana", "validated_at": "2026-07-02T15:45:41.375970Z"}', 200, NULL, NULL, 'success', 'sanitized-license.json', '2026-07-02 15:45:41.380955+00', '2026-07-02 15:45:41.380955+00');


--
-- Data for Name: tenant_license_activations; Type: TABLE DATA; Schema: public; Owner: postgres
--

INSERT INTO "public"."tenant_license_activations" ("id", "idTenant", "rawPayload", "licenseBundle", "activationRequest", "activationResponse", "mode", "productCode", "customerId", "planName", "jti", "kid", "totalDays", "expiresAt", "validatedAt", "source", "warning", "status", "uploadedFilename", "createdAt", "updatedAt") VALUES
	(1, 1, '{}', '{}', '{}', '{"mode": "ONLINE_SYNCED", "params": {"maxMessages": 10000, "studioIntegrated": true}, "source": "keyforge", "warning": null, "plan_name": "studio", "expires_at": "2027-05-10T00:00:00Z", "total_days": 364, "customer_id": "internal", "product_code": "daiana", "validated_at": "2026-07-02T15:45:41.375970Z"}', 'ONLINE_SYNCED', 'daiana', 'internal', 'studio', '00000000-0000-0000-0000-000000000000', 'sanitized-key-id', 364, '2027-05-10 00:00:00+00', '2026-07-02 15:45:41.375970+00', 'keyforge', NULL, 'active', 'sanitized-license.json', '2026-07-02 15:45:41.380955+00', '2026-07-02 15:45:41.380955+00');

--
-- Data for Name: tenant_plans; Type: TABLE DATA; Schema: public; Owner: postgres
--

INSERT INTO "public"."tenant_plans" ("id", "idTenant", "planName", "maxMessages", "studioIntegrated", "periodStartAt", "expiresAt", "validatedAt", "status", "createdAt", "updatedAt") VALUES
	(1, 1, 'studio', 10000, true, '2026-07-01 18:17:56.434953+00', '2027-05-10 00:00:00+00', '2026-07-01 18:17:56.434953+00', 'active', '2026-07-01 18:17:56.682909+00', '2026-07-01 18:17:56.489445+00');


--
-- Data for Name: training; Type: TABLE DATA; Schema: public; Owner: postgres
--



--
-- Name: aibot_idBot_seq; Type: SEQUENCE SET; Schema: public; Owner: supabase_admin
--

SELECT pg_catalog.setval('"public"."aibot_idBot_seq"', 1, true);


--
-- Name: databases_id_seq; Type: SEQUENCE SET; Schema: public; Owner: supabase_admin
--

SELECT pg_catalog.setval('"public"."databases_id_seq"', 1, false);


--
-- Name: history_id_seq; Type: SEQUENCE SET; Schema: public; Owner: supabase_admin
--

SELECT pg_catalog.setval('"public"."history_id_seq"', 1, false);


--
-- Name: tenant_license_activation_attempts_id_seq; Type: SEQUENCE SET; Schema: public; Owner: supabase_admin
--

SELECT pg_catalog.setval('"public"."tenant_license_activation_attempts_id_seq"', 1, false);


--
-- Name: tenant_license_activations_id_seq; Type: SEQUENCE SET; Schema: public; Owner: supabase_admin
--

SELECT pg_catalog.setval('"public"."tenant_license_activations_id_seq"', 1, false);


--
-- Name: tenant_plans_id_seq; Type: SEQUENCE SET; Schema: public; Owner: supabase_admin
--

SELECT pg_catalog.setval('"public"."tenant_plans_id_seq"', 1, false);


--
-- Name: tenants_idTenant_seq; Type: SEQUENCE SET; Schema: public; Owner: supabase_admin
--

SELECT pg_catalog.setval('"public"."tenants_idTenant_seq"', 1, true);


--
-- PostgreSQL database dump complete
--

-- \unrestrict Cw59pJqVDg4JCsda62ds7MnxdlGc8bWltNGOYJABJzSj7jlKsbt2ecg4TdNudhf

RESET ALL;

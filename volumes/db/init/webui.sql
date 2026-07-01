SET session_replication_role = replica;

--
-- PostgreSQL database dump
--

-- \restrict w9ndQpJlv71FTqACQpk3g44sZK91Plj0bxdgUvbqrl2jtKtShgqjEz3tDCc2Bln

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
-- Data for Name: alembic_version; Type: TABLE DATA; Schema: webui; Owner: webui
--

INSERT INTO "webui"."alembic_version" ("version_num") VALUES
	('38d63c18f30f');


--
-- Data for Name: auth; Type: TABLE DATA; Schema: webui; Owner: webui
--

INSERT INTO "webui"."auth" ("id", "email", "password", "active") VALUES
	('354611b1-7089-4a0a-bf38-16625e4d9858', 'cloud@seidoranalytics.com', '$2b$12$.HJu/KjH2ucfBdf5/wydQOo7V3wfeMNWL4sA.DYhOCe793adRTReq', true);


--
-- Data for Name: channel; Type: TABLE DATA; Schema: webui; Owner: webui
--



--
-- Data for Name: channel_member; Type: TABLE DATA; Schema: webui; Owner: webui
--



--
-- Data for Name: chat; Type: TABLE DATA; Schema: webui; Owner: webui
--



--
-- Data for Name: chatidtag; Type: TABLE DATA; Schema: webui; Owner: webui
--



--
-- Data for Name: config; Type: TABLE DATA; Schema: webui; Owner: webui
--

INSERT INTO "webui"."config" ("id", "data", "version", "created_at", "updated_at") VALUES
	(1, '{"version": 0, "ui": {"enable_signup": false}}', 0, '2026-06-26 20:32:52.003485', NULL);


--
-- Data for Name: document; Type: TABLE DATA; Schema: webui; Owner: webui
--



--
-- Data for Name: feedback; Type: TABLE DATA; Schema: webui; Owner: webui
--



--
-- Data for Name: file; Type: TABLE DATA; Schema: webui; Owner: webui
--



--
-- Data for Name: folder; Type: TABLE DATA; Schema: webui; Owner: webui
--



--
-- Data for Name: function; Type: TABLE DATA; Schema: webui; Owner: webui
--

INSERT INTO "webui"."function" ("id", "user_id", "name", "type", "content", "meta", "created_at", "updated_at", "valves", "is_active", "is_global") VALUES
	('new_func', '354611b1-7089-4a0a-bf38-16625e4d9858', 'Daiana Studio', 'pipe', '"""
title: Daiana Integration for OpenWebUI
version: 1.0.5
description: Daiana integration with dynamic model loading, streaming, UI feedback, and image/artifact rendering
Requirements:
  - Daiana API URL (set via DAIANA_API_URL)
  - Daiana API Key (set via DAIANA_API_KEY)
"""

from urllib.parse import quote
from pydantic import BaseModel, Field
from typing import (
    Optional,
    Dict,
    Any,
    List,
    Union,
    Generator,
    Iterator,
    Callable,
    Awaitable,
)
import requests
import json
import os
import time
import asyncio
import re
from urllib.parse import urljoin


class Pipe:
    class Valves(BaseModel):
        daiana_url: str = Field(
            default=os.getenv("DAIANA_API_URL", "http://localhost:3001"),
            description="Daiana Studio API base URL",
        )
        daiana_api_key: str = Field(
            default=os.getenv("DAIANA_API_KEY", ""),
            description="Daiana Studio API key for authentication",
        )
        enable_status_indicator: bool = Field(
            default=True, description="Enable status indicators in the UI"
        )
        emit_interval: float = Field(
            default=1.0, description="Interval between status emissions (seconds)"
        )
        timeout: int = Field(
            default=(
                int(os.getenv("DAIANA_TIMEOUT", "600"))
                if os.getenv("DAIANA_TIMEOUT", "").isdigit()
                else 600
            ),
            description="Request timeout in seconds",
        )
        connect_timeout: int = Field(
            default=(
                int(os.getenv("DAIANA_CONNECT_TIMEOUT", "15"))
                if os.getenv("DAIANA_CONNECT_TIMEOUT", "").isdigit()
                else 15
            ),
            description="Connection timeout in seconds",
        )
        read_timeout: int = Field(
            default=(
                int(os.getenv("DAIANA_READ_TIMEOUT", "600"))
                if os.getenv("DAIANA_READ_TIMEOUT", "").isdigit()
                else 600
            ),
            description="Read timeout in seconds (non-streaming)",
        )
        read_timeout_stream: int = Field(
            default=(
                int(os.getenv("DAIANA_READ_TIMEOUT_STREAM", "1800"))
                if os.getenv("DAIANA_READ_TIMEOUT_STREAM", "").isdigit()
                else 1800
            ),
            description="Read timeout in seconds for streaming responses",
        )
        debug_mode: bool = Field(default=False, description="Enable debug logging")
        send_history: bool = Field(
            default=False,
            description="Si es True, envía el historial (history) a Flowise. Si es False, no envía history.",
        )
        history_max_messages: int = Field(
            default=20,
            ge=0,
            description="Cantidad máxima de mensajes previos a enviar en history. 0 = no enviar ninguno.",
        )
        render_images: bool = Field(
            default=True,
            description="Render image URLs/base64 returned by Flowise as Markdown images.",
        )
        public_base_url: str = Field(
            default=os.getenv("DAIANA_PUBLIC_BASE_URL", ""),
            description="Public base URL to resolve relative image paths. Example: https://studio.daianadev.seidoranalytics.com",
        )

    def __init__(self):
        self.type = "manifold"
        self.id = "daiana"
        self.name = "- "
        self.valves = self.Valves()
        self.last_emit_time = 0

        if not self.valves.daiana_url:
            print("⚠️ Please set DAIANA_API_URL")
        if not self.valves.daiana_api_key:
            print("⚠️ Please set DAIANA_API_KEY")

    def _get_request_timeout(self, stream_enabled: bool = False):
        if os.getenv("DAIANA_TIMEOUT"):
            return (self.valves.timeout, self.valves.timeout)

        return (
            self.valves.connect_timeout,
            (
                self.valves.read_timeout_stream
                if stream_enabled
                else self.valves.read_timeout
            ),
        )

    def _public_base(self) -> str:
        return (self.valves.public_base_url or self.valves.daiana_url or "").rstrip("/")

    def _is_image_url_or_data(self, value: str) -> bool:
        if not value or not isinstance(value, str):
            return False

        value = value.strip()

        if value.startswith("data:image/"):
            return True

        if value.startswith("FILE-STORAGE::"):
            return True

        image_extensions = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg")
        clean_value = value.split("?")[0].split("#")[0].lower()

        if clean_value.endswith(image_extensions):
            return True

        if "/api/v1/get-upload-file" in value:
            return True

        if "/uploads/" in value:
            return True

        return False

    def _normalize_image_url(self, value: str) -> str:
        value = value.strip()
        if value.startswith("FILE-STORAGE::"):
            file_name = value.replace("FILE-STORAGE::", "").strip()

            chatflow_id = getattr(self, "_current_model_id", "")
            chat_id = getattr(self, "_current_session_id", "")

            return (
                f"{self._public_base()}/api/v1/get-upload-file"
                f"?chatflowId={quote(chatflow_id)}"
                f"&chatId={quote(chat_id)}"
                f"&fileName={quote(file_name)}"
            )

        if value.startswith("data:image/"):
            return value

        if value.startswith("http://") or value.startswith("https://"):
            return value

        base = self._public_base()

        if value.startswith("/"):
            return f"{base}{value}"

        if value.startswith("uploads/") or value.startswith("storage/"):
            return f"{base}/{value}"

        if "/home/node/.flowise/storage/" in value:
            filename = value.split("/home/node/.flowise/storage/")[-1]
            return f"{base}/{filename}"

        return urljoin(f"{base}/", value)

    def _extract_images_from_any(
        self, obj: Any, images: Optional[List[str]] = None
    ) -> List[str]:
        if images is None:
            images = []

        if obj is None:
            return images

        if isinstance(obj, str):
            text = obj.strip()

            if self._is_image_url_or_data(text):
                images.append(self._normalize_image_url(text))

            md_images = re.findall(r"!\[[^\]]*\]\(([^)]+)\)", text)
            for url in md_images:
                if self._is_image_url_or_data(url):
                    images.append(self._normalize_image_url(url))

            return images

        if isinstance(obj, list):
            for item in obj:
                self._extract_images_from_any(item, images)
            return images

        if isinstance(obj, dict):
            preferred_keys = [
                "url",
                "src",
                "data",
                "image",
                "imageUrl",
                "image_url",
                "downloadUrl",
                "fileUrl",
                "file_url",
                "path",
                "blob",
                "base64",
            ]

            for key in preferred_keys:
                if key in obj:
                    self._extract_images_from_any(obj.get(key), images)

            nested_keys = [
                "images",
                "artifacts",
                "fileUploads",
                "uploads",
                "generatedImages",
                "output",
                "outputs",
                "result",
                "results",
                "data",
                "content",
                "message",
                "response",
                "text",
            ]

            for key in nested_keys:
                if key in obj:
                    self._extract_images_from_any(obj.get(key), images)

            return images

        return images

    def _extract_images_markdown(self, data: Any) -> str:
        if not self.valves.render_images:
            return ""

        images = self._extract_images_from_any(data)

        seen = set()
        unique_images = []
        for img in images:
            if img and img not in seen:
                seen.add(img)
                unique_images.append(img)

        if not unique_images:
            return ""

        return "\n\n".join([f"![Imagen generada]({img})" for img in unique_images])

    def _extract_text_from_response(self, response_data: Any) -> str:
        if isinstance(response_data, str):
            return response_data

        if not isinstance(response_data, dict):
            return str(response_data)

        for key in [
            "text",
            "message",
            "content",
            "response",
            "answer",
            "result",
            "output",
        ]:
            value = response_data.get(key)
            if value is None:
                continue

            if isinstance(value, bytes):
                value = value.decode("utf-8", errors="ignore")

            if isinstance(value, str):
                return value

            if isinstance(value, dict):
                for nested_key in ["text", "message", "content", "response", "answer"]:
                    nested_value = value.get(nested_key)
                    if isinstance(nested_value, str):
                        return nested_value

            if isinstance(value, list):
                texts = []
                for item in value:
                    if isinstance(item, str):
                        texts.append(item)
                    elif isinstance(item, dict):
                        for nested_key in ["text", "message", "content", "response"]:
                            if isinstance(item.get(nested_key), str):
                                texts.append(item.get(nested_key))
                if texts:
                    return "\n\n".join(texts)

        return ""

    def _combine_text_and_images(self, text: str, response_data: Any) -> str:
        images_md = self._extract_images_markdown(response_data)

        if text and images_md:
            return f"{text}\n\n{images_md}"

        if images_md:
            return images_md

        if text:
            return text

        return str(response_data)

    def pipes(self) -> List[Dict[str, str]]:
        if not self.valves.daiana_api_key or not self.valves.daiana_url:
            return [
                {
                    "id": "error",
                    "name": "❌ Missing API configuration - Please set DAIANA_API_URL and DAIANA_API_KEY",
                }
            ]

        try:
            headers = {
                "Authorization": f"Bearer {self.valves.daiana_api_key}",
                "Content-Type": "application/json; charset=utf-8",
            }

            response = requests.get(
                f"{self.valves.daiana_url}/api/v1/chatflows",
                headers=headers,
                timeout=self._get_request_timeout(stream_enabled=False),
            )
            response.raise_for_status()
            response.encoding = "utf-8"

            chatflows = response.json()

            if not chatflows:
                return [
                    {
                        "id": "no_flows",
                        "name": "ℹ️ No chatflows found in your Daiana instance",
                    }
                ]

            available_pipes = []

            for flow in chatflows:
                flow_name = flow.get("name", "Unnamed Flow")
                flow_id = flow.get("id", "")

                if "agent" in flow_name.lower():
                    emoji = "🤖"
                elif "chat" in flow_name.lower():
                    emoji = "💬"
                elif "image" in flow_name.lower() or "imagen" in flow_name.lower():
                    emoji = "🖼️"
                else:
                    emoji = "🔄"

                available_pipes.append(
                    {
                        "id": flow_id,
                        "name": f"{emoji} {flow_name}",
                    }
                )

            return available_pipes

        except requests.exceptions.Timeout:
            return [
                {
                    "id": "timeout_error",
                    "name": "⏰ Connection timeout - Check your Daiana Studio URL and network",
                }
            ]
        except requests.exceptions.ConnectionError:
            return [
                {
                    "id": "connection_error",
                    "name": "🔌 Connection failed - Is Daiana Studio running?",
                }
            ]
        except Exception as e:
            error_msg = f"⚠️ Error loading chatflows: {str(e)}"
            if self.valves.debug_mode:
                print(f"Debug - pipes() error: {e}")
            return [{"id": "error", "name": error_msg}]

    async def emit_status(
        self,
        __event_emitter__: Optional[Callable[[dict], Awaitable[None]]],
        level: str,
        message: str,
        done: bool = False,
    ):
        current_time = time.time()

        if (
            __event_emitter__
            and self.valves.enable_status_indicator
            and (
                current_time - self.last_emit_time >= self.valves.emit_interval or done
            )
        ):
            try:
                await __event_emitter__(
                    {
                        "type": "status",
                        "data": {
                            "status": "complete" if done else "in_progress",
                            "level": level,
                            "description": message,
                            "done": done,
                        },
                    }
                )
                self.last_emit_time = current_time
            except Exception as e:
                if self.valves.debug_mode:
                    print(f"Debug - emit_status error: {e}")

    def _process_message_content(self, message: dict) -> str:
        content = message.get("content", "")

        if isinstance(content, list):
            processed_content = []

            for item in content:
                if isinstance(item, dict):
                    if item.get("type") == "text":
                        processed_content.append(item.get("text", ""))
                    elif item.get("type") == "image_url":
                        image_url = item.get("image_url", {})
                        if isinstance(image_url, dict):
                            processed_content.append(
                                image_url.get("url", "[Image content]")
                            )
                        elif isinstance(image_url, str):
                            processed_content.append(image_url)
                        else:
                            processed_content.append("[Image content]")
                else:
                    processed_content.append(str(item))

            return "\n\n".join([str(p) for p in processed_content if str(p)])

        return str(content) if content else ""

    def _build_history_payload(self, messages: List[dict]) -> List[Dict[str, str]]:
        history: List[Dict[str, str]] = []

        for msg in messages:
            role = msg.get("role", "user")
            content = self._process_message_content(msg).strip()

            if not content:
                continue

            if role not in {"user", "assistant", "system"}:
                role = (
                    "user"
                    if role == "tool"
                    else "assistant" if role == "model" else "user"
                )

            history.append({"role": role, "content": content})

        return history

    async def pipe(
        self,
        body: dict,
        __user__: Optional[dict] = None,
        __event_emitter__: Optional[Callable[[dict], Awaitable[None]]] = None,
        __event_call__: Optional[Callable[[dict], Awaitable[dict]]] = None,
        __metadata__: Optional[dict] = None,
    ) -> Union[str, Generator, Iterator]:

        response = None

        try:
            await self.emit_status(
                __event_emitter__,
                "info",
                "🚀 Initializing Daiana Studio request...",
                False,
            )

            if self.valves.debug_mode:
                print("\nDebug - Processing request:")
                print(f"Body: {json.dumps(body, indent=2, ensure_ascii=False)}")
                print(f"Metadata: {__metadata__}")

            if not self.valves.daiana_api_key or not self.valves.daiana_url:
                error_msg = "❌ Missing Daiana Studio configuration. Please check your API URL and key."
                await self.emit_status(__event_emitter__, "error", error_msg, True)
                return error_msg

            model_info = body.get("model", "")

            if "." in model_info:
                model_id = model_info.split(".", 1)[1]
            else:
                model_id = model_info

            messages = body.get("messages", [])

            if not messages:
                error_msg = "❌ No messages found in request"
                await self.emit_status(__event_emitter__, "error", error_msg, True)
                return error_msg

            current_message = messages[-1]
            question = self._process_message_content(current_message)

            if not question.strip():
                error_msg = "❌ Empty message content"
                await self.emit_status(__event_emitter__, "error", error_msg, True)
                return error_msg

            await self.emit_status(
                __event_emitter__,
                "info",
                "🔄 Sending request to Daiana...",
                False,
            )

            stream_enabled = body.get("stream", True)

            base_chat_id = (
                __metadata__.get("chat_id", f"session_{int(time.time())}")
                if __metadata__
                else f"session_{int(time.time())}"
            )

            session_id = f"{base_chat_id}:{model_id}"

            self._current_model_id = model_id
            self._current_session_id = session_id

            user_override_config = {}

            if isinstance(body.get("overrideConfig"), dict):
                user_override_config = body.get("overrideConfig", {})
            elif isinstance(body.get("daiana_override"), dict):
                user_override_config = body.get("daiana_override", {})

            override_config: Dict[str, Any] = {"sessionId": session_id}

            override_config.update(
                {k: v for k, v in user_override_config.items() if k != "sessionId"}
            )

            prior_messages = []

            if self.valves.send_history and self.valves.history_max_messages > 0:
                prior_messages = messages[:-1][-self.valves.history_max_messages :]

            history_payload = (
                self._build_history_payload(prior_messages) if prior_messages else []
            )

            request_data: Dict[str, Any] = {
                "question": question,
                "overrideConfig": override_config,
                "streaming": stream_enabled,
            }

            if history_payload:
                request_data["history"] = history_payload

            if __metadata__:
                request_data["metadata"] = __metadata__

            if __user__ and isinstance(__user__, dict):
                request_data["user"] = {
                    k: __user__.get(k)
                    for k in ("id", "name", "email")
                    if __user__.get(k) is not None
                }

            headers = {
                "Authorization": f"Bearer {self.valves.daiana_api_key}",
                "Content-Type": "application/json; charset=utf-8",
                "Accept": (
                    "text/event-stream; charset=utf-8"
                    if stream_enabled
                    else "application/json; charset=utf-8"
                ),
            }

            if self.valves.debug_mode:
                print(
                    f"Debug - Request URL: {self.valves.daiana_url}/api/v1/prediction/{model_id}"
                )
                print(
                    f"Debug - Request data: {json.dumps(request_data, indent=2, ensure_ascii=False)}"
                )
                print(f"Debug - Headers: {headers}")
                print(f"Debug - Stream enabled: {stream_enabled}")
                print(
                    f"Debug - Timeout: {self._get_request_timeout(stream_enabled=stream_enabled)}"
                )

            response = requests.post(
                url=f"{self.valves.daiana_url}/api/v1/prediction/{model_id}",
                json=request_data,
                headers=headers,
                timeout=self._get_request_timeout(stream_enabled=stream_enabled),
                stream=stream_enabled,
            )

            response.raise_for_status()
            response.encoding = "utf-8"

            if self.valves.debug_mode:
                print(f"Debug - Response status: {response.status_code}")
                print(f"Debug - Response headers: {dict(response.headers)}")

            await self.emit_status(
                __event_emitter__,
                "info",
                "✅ Receiving response from Daiana...",
                False,
            )

            if stream_enabled:
                return self._handle_streaming_response(response, __event_emitter__)

            await self.emit_status(
                __event_emitter__,
                "info",
                "📝 Processing response...",
                False,
            )

            try:
                response_data = response.json()
            except json.JSONDecodeError:
                text_response = response.text

                if self.valves.debug_mode:
                    print(f"Debug - Raw response: {text_response}")

                await self.emit_status(
                    __event_emitter__,
                    "info",
                    "✅ Response ready!",
                    True,
                )

                return text_response

            if self.valves.debug_mode:
                print(
                    f"Debug - Response data: {json.dumps(response_data, indent=2, ensure_ascii=False)}"
                )

            result_text = self._extract_text_from_response(response_data)
            final_result = self._combine_text_and_images(result_text, response_data)

            await self.emit_status(
                __event_emitter__,
                "info",
                "✅ Response ready!",
                True,
            )

            return final_result

        except requests.exceptions.Timeout:
            error_msg = f"⏰ Request timeout after {self.valves.timeout} seconds"
            await self.emit_status(__event_emitter__, "error", error_msg, True)
            return error_msg

        except requests.exceptions.ConnectionError:
            error_msg = "🔌 Connection failed - Is Daiana running and accessible?"
            await self.emit_status(__event_emitter__, "error", error_msg, True)
            return error_msg

        except requests.exceptions.HTTPError as e:
            status_code = response.status_code if response is not None else "unknown"
            error_msg = f"🚫 HTTP Error {status_code}: {e}"
            await self.emit_status(__event_emitter__, "error", error_msg, True)
            return error_msg

        except Exception as e:
            error_msg = f"❌ Unexpected error: {str(e)}"
            if self.valves.debug_mode:
                print(f"Debug - pipe() error: {e}")
            await self.emit_status(__event_emitter__, "error", error_msg, True)
            return error_msg

    def _handle_streaming_response(
        self,
        response: requests.Response,
        __event_emitter__: Optional[Callable[[dict], Awaitable[None]]],
    ) -> Generator[str, None, None]:

        yielded_images = set()

        try:
            # chunk_size=1 forces requests to read the socket one byte at a
            # time. This is irrelevant for normal short token lines, but
            # Flowise sometimes emits a single SSE line containing a huge
            # tool-call payload (e.g. an "usedTools" event with a full node
            # listing, several MB of JSON). Reading that byte-by-byte makes
            # the request take an extremely long time (looks like an
            # infinite "sending" state) even though the answer text already
            # finished. A larger chunk size still yields lines as soon as
            # they''re available, but with far fewer read syscalls.
            for raw_line in response.iter_lines(decode_unicode=True, chunk_size=8192):
                line = raw_line.strip() if isinstance(raw_line, str) else raw_line

                if self.valves.debug_mode and line:
                    print(f"Debug - Streaming line: {line}")

                if not line:
                    continue

                if isinstance(line, str) and (
                    line.startswith("event:")
                    or line.startswith("id:")
                    or line.startswith("retry:")
                    or line.startswith(":heartbeat")
                    or line.strip() == "message:"
                ):
                    continue

                if isinstance(line, str) and line.startswith("data:"):
                    try:
                        json_data = line[5:].strip()

                        if not json_data:
                            continue

                        if json_data == "[DONE]":
                            break

                        data = json.loads(json_data)

                        if self.valves.debug_mode:
                            print(
                                f"Debug - Parsed streaming data: {json.dumps(data, indent=2, ensure_ascii=False)}"
                            )

                        images_md = self._extract_images_markdown(data)

                        if images_md and images_md not in yielded_images:
                            yielded_images.add(images_md)
                            yield f"\n\n{images_md}\n\n"

                        if isinstance(data, dict) and data.get("event") == "token":
                            token = data.get("data", "")
                            if token:
                                if isinstance(token, bytes):
                                    token = token.decode("utf-8", errors="ignore")

                                token = str(token)
                                token = token.replace("message:", "")
                                token = token.replace(":heartbeat", "")

                                # IMPORTANT: do NOT use `token.strip()` here to decide
                                # whether to yield. Flowise streams token-by-token, and
                                # some tokens are pure whitespace (a single "\n" or " ").
                                # `token.strip()` on those evaluates to an empty string
                                # (falsy), which silently drops the token and breaks
                                # markdown formatting (missing line breaks / spaces).
                                # We only need to check that the token is non-empty.
                                if token:
                                    yield token

                        elif isinstance(data, dict) and data.get("event") in {
                            "start",
                            "end",
                            "error",
                            "status",
                        }:
                            desc = (
                                data.get("data")
                                or data.get("message")
                                or data.get("text")
                                or ""
                            )

                            if __event_emitter__ and desc:
                                try:
                                    level = (
                                        "error"
                                        if data.get("event") == "error"
                                        else "info"
                                    )
                                    asyncio.create_task(
                                        self.emit_status(
                                            __event_emitter__,
                                            level,
                                            str(desc),
                                            data.get("event") == "end",
                                        )
                                    )
                                except Exception:
                                    pass

                            # Flowise signals completion with "event": "end" and
                            # failures with "event": "error". Previously the loop
                            # only stopped on a literal "[DONE]" string, which
                            # Flowise does not send — so if the connection wasn''t
                            # closed right away, the generator kept blocking on
                            # iter_lines() forever even though the full answer had
                            # already been yielded, leaving OpenWebUI stuck on
                            # "generating". Break explicitly on these events.
                            if data.get("event") in {"end", "error"}:
                                break

                        elif isinstance(data, dict) and "text" in data:
                            final_text = data["text"]

                            if isinstance(final_text, bytes):
                                final_text = final_text.decode("utf-8", errors="ignore")

                            if isinstance(final_text, str) and final_text:
                                yield final_text

                            if __event_emitter__:
                                try:
                                    asyncio.create_task(
                                        self.emit_status(
                                            __event_emitter__,
                                            "info",
                                            "✅ Response complete",
                                            True,
                                        )
                                    )
                                except Exception:
                                    pass

                        elif isinstance(data, dict) and "response" in data:
                            msg = data.get("response")
                            if isinstance(msg, str) and msg:
                                yield msg

                        elif isinstance(data, str):
                            yield data

                        elif isinstance(data, dict) and "choices" in data:
                            try:
                                deltas = [
                                    c.get("delta", {}).get("content")
                                    for c in data.get("choices", [])
                                ]
                                for delta in deltas:
                                    if delta:
                                        yield delta
                            except Exception:
                                pass

                    except json.JSONDecodeError as e:
                        if self.valves.debug_mode:
                            print(f"Debug - JSON decode error: {e} for line: {line}")
                        continue

                    except UnicodeDecodeError as e:
                        if self.valves.debug_mode:
                            print(f"Debug - Unicode decode error: {e}")
                        continue

            if __event_emitter__:
                try:
                    asyncio.create_task(
                        self.emit_status(
                            __event_emitter__,
                            "info",
                            "✅ Response complete",
                            True,
                        )
                    )
                except Exception:
                    pass

        except requests.exceptions.ReadTimeout as e:
            effective_timeout = self._get_request_timeout(stream_enabled=True)
            error_msg = (
                f"⏰ Streaming read timed out (connect, read)={effective_timeout}. "
                f"Increase DAIANA_READ_TIMEOUT_STREAM or unset DAIANA_TIMEOUT if set."
            )
            if self.valves.debug_mode:
                print(f"Debug - streaming read timeout: {e}")
            yield error_msg

        except Exception as e:
            error_msg = f"❌ Streaming error: {str(e)}"
            if self.valves.debug_mode:
                print(f"Debug - streaming error: {e}")
            yield error_msg
', '{"description": "Daiana Studio Function Pipe", "manifest": {"title": "Daiana Integration for OpenWebUI", "version": "1.0.5", "description": "Daiana integration with dynamic model loading, streaming, UI feedback, and image/artifact rendering", "Requirements": ""}}', 1782930046, 1782930097, 'null', false, false);


--
-- Data for Name: group; Type: TABLE DATA; Schema: webui; Owner: webui
--



--
-- Data for Name: knowledge; Type: TABLE DATA; Schema: webui; Owner: webui
--



--
-- Data for Name: memory; Type: TABLE DATA; Schema: webui; Owner: webui
--



--
-- Data for Name: message; Type: TABLE DATA; Schema: webui; Owner: webui
--



--
-- Data for Name: message_reaction; Type: TABLE DATA; Schema: webui; Owner: webui
--



--
-- Data for Name: migratehistory; Type: TABLE DATA; Schema: webui; Owner: webui
--

INSERT INTO "webui"."migratehistory" ("id", "name", "migrated_at") VALUES
	(1, '001_initial_schema', '2026-06-26 01:19:28.660427'),
	(2, '002_add_local_sharing', '2026-06-26 01:19:28.889597'),
	(3, '003_add_auth_api_key', '2026-06-26 01:19:28.937507'),
	(4, '004_add_archived', '2026-06-26 01:19:29.025095'),
	(5, '005_add_updated_at', '2026-06-26 01:19:29.168197'),
	(6, '006_migrate_timestamps_and_charfields', '2026-06-26 01:19:29.238069'),
	(7, '007_add_user_last_active_at', '2026-06-26 01:19:29.386122'),
	(8, '008_add_memory', '2026-06-26 01:19:29.442661'),
	(9, '009_add_models', '2026-06-26 01:19:29.543272'),
	(10, '010_migrate_modelfiles_to_models', '2026-06-26 01:19:29.630991'),
	(11, '011_add_user_settings', '2026-06-26 01:19:29.719551'),
	(12, '012_add_tools', '2026-06-26 01:19:29.818777'),
	(13, '013_add_user_info', '2026-06-26 01:19:29.86222'),
	(14, '014_add_files', '2026-06-26 01:19:29.947355'),
	(15, '015_add_functions', '2026-06-26 01:19:30.008623'),
	(16, '016_add_valves_and_is_active', '2026-06-26 01:19:30.072237'),
	(17, '017_add_user_oauth_sub', '2026-06-26 01:19:30.164399'),
	(18, '018_add_function_is_global', '2026-06-26 01:19:30.220297');


--
-- Data for Name: model; Type: TABLE DATA; Schema: webui; Owner: webui
--



--
-- Data for Name: note; Type: TABLE DATA; Schema: webui; Owner: webui
--



--
-- Data for Name: user; Type: TABLE DATA; Schema: webui; Owner: webui
--

INSERT INTO "webui"."user" ("id", "name", "email", "role", "profile_image_url", "api_key", "created_at", "updated_at", "last_active_at", "settings", "info", "oauth_sub", "username", "bio", "gender", "date_of_birth") VALUES
	('354611b1-7089-4a0a-bf38-16625e4d9858', 'Cloud Seidor Analytics', 'cloud@seidoranalytics.com', 'admin', 'data:image/png;base64,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', NULL, 1782505971, 1782505971, 1782506069, '{"ui": {"version": "0.6.30"}}', 'null', NULL, NULL, NULL, NULL, NULL);


--
-- Data for Name: oauth_session; Type: TABLE DATA; Schema: webui; Owner: webui
--



--
-- Data for Name: prompt; Type: TABLE DATA; Schema: webui; Owner: webui
--



--
-- Data for Name: tag; Type: TABLE DATA; Schema: webui; Owner: webui
--



--
-- Data for Name: tool; Type: TABLE DATA; Schema: webui; Owner: webui
--



--
-- Name: config_id_seq; Type: SEQUENCE SET; Schema: webui; Owner: webui
--

SELECT pg_catalog.setval('"webui"."config_id_seq"', 1, true);


--
-- Name: document_id_seq; Type: SEQUENCE SET; Schema: webui; Owner: webui
--

SELECT pg_catalog.setval('"webui"."document_id_seq"', 1, false);


--
-- Name: migratehistory_id_seq; Type: SEQUENCE SET; Schema: webui; Owner: webui
--

SELECT pg_catalog.setval('"webui"."migratehistory_id_seq"', 18, true);


--
-- Name: prompt_id_seq; Type: SEQUENCE SET; Schema: webui; Owner: webui
--

SELECT pg_catalog.setval('"webui"."prompt_id_seq"', 1, false);


--
-- PostgreSQL database dump complete
--

-- \unrestrict w9ndQpJlv71FTqACQpk3g44sZK91Plj0bxdgUvbqrl2jtKtShgqjEz3tDCc2Bln

RESET ALL;

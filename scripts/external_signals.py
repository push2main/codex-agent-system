#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import html
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from typing import Any


DEFAULT_REFRESH_COOLDOWN_SECONDS = 21600
DEFAULT_FRESHNESS_WINDOW_SECONDS = 604800
DEFAULT_REQUEST_TIMEOUT_SECONDS = 8
DEFAULT_SEARCH_URL = "https://duckduckgo.com/html/?q={query}"


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def now_utc_text() -> str:
    return now_utc().strftime("%Y-%m-%dT%H:%M:%SZ")


def read_json(path: str, fallback: dict[str, Any]) -> dict[str, Any]:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
        if isinstance(payload, dict):
            return payload
    except Exception:
        pass
    return dict(fallback)


def write_json(path: str, payload: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=os.path.dirname(path), encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
        temp_path = handle.name
    os.replace(temp_path, path)


def safe_int(value: Any, fallback: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return fallback


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def slugify(value: Any) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9]+", "-", str(value or "").strip().lower())) or "signal"


def strip_html(value: Any) -> str:
    text = re.sub(r"<[^>]+>", " ", str(value or ""))
    return normalize_text(html.unescape(text))


def parse_datetime(value: Any) -> datetime | None:
    text = str(value or "").strip()
    if not text:
        return None
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        pass
    try:
        return parsedate_to_datetime(text).astimezone(timezone.utc)
    except (TypeError, ValueError, IndexError):
        return None


def format_datetime(value: datetime | None) -> str:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if isinstance(value, datetime) else ""


def request_bytes(url: str, timeout_seconds: int, *, accept: str) -> bytes:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "codex-agent-system-external-signals/1.0",
            "Accept": accept,
        },
    )
    with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
        return response.read()


def read_bytes(source: dict[str, Any], timeout_seconds: int) -> bytes:
    local_path = str(source.get("path") or "").strip()
    if local_path:
        with open(local_path, "rb") as handle:
            return handle.read()
    url = str(source.get("url") or "").strip()
    if not url:
        raise ValueError("source requires either path or url")
    return request_bytes(
        url,
        timeout_seconds,
        accept="application/atom+xml, application/rss+xml, application/xml, text/xml;q=0.9, text/html;q=0.8",
    )


def read_text_resource(path: str = "", url: str = "", timeout_seconds: int = DEFAULT_REQUEST_TIMEOUT_SECONDS) -> str:
    if path:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read()
    if url:
        return request_bytes(url, timeout_seconds, accept="text/plain, text/vtt, application/x-subrip, text/html;q=0.8").decode(
            "utf-8", errors="replace"
        )
    raise ValueError("text resource requires path or url")


def find_text(element: ET.Element | None, *names: str) -> str:
    if element is None:
        return ""
    for name in names:
        node = element.find(name)
        if node is not None and node.text:
            text = normalize_text(node.text)
            if text:
                return text
    return ""


def parse_rss(root: ET.Element) -> list[dict[str, str]]:
    channel = root.find("channel")
    if channel is None:
        return []
    entries: list[dict[str, str]] = []
    for item in channel.findall("item"):
        entries.append(
            {
                "entry_id": find_text(item, "guid") or find_text(item, "link") or find_text(item, "title"),
                "title": find_text(item, "title"),
                "url": find_text(item, "link"),
                "published_at": find_text(item, "pubDate"),
                "summary": strip_html(find_text(item, "description")),
            }
        )
    return entries


def parse_atom(root: ET.Element) -> list[dict[str, str]]:
    namespace = ""
    if root.tag.startswith("{") and "}" in root.tag:
        namespace = root.tag.split("}", 1)[0] + "}"
    entries: list[dict[str, str]] = []
    for entry in root.findall(f"{namespace}entry"):
        link_url = ""
        for link in entry.findall(f"{namespace}link"):
            rel = str(link.attrib.get("rel") or "alternate").strip().lower()
            href = normalize_text(link.attrib.get("href") or "")
            if not href:
                continue
            if rel == "alternate":
                link_url = href
                break
            if not link_url:
                link_url = href
        entries.append(
            {
                "entry_id": find_text(entry, f"{namespace}id") or link_url or find_text(entry, f"{namespace}title"),
                "title": find_text(entry, f"{namespace}title"),
                "url": link_url,
                "published_at": find_text(entry, f"{namespace}updated") or find_text(entry, f"{namespace}published"),
                "summary": strip_html(find_text(entry, f"{namespace}summary") or find_text(entry, f"{namespace}content")),
            }
        )
    return entries


def parse_feed(content: bytes) -> list[dict[str, str]]:
    root = ET.fromstring(content)
    tag = root.tag.rsplit("}", 1)[-1].lower()
    if tag == "rss":
        return parse_rss(root)
    if tag == "feed":
        return parse_atom(root)
    raise ValueError(f"unsupported feed root: {tag}")


def parse_web_search_results(source: dict[str, Any], timeout_seconds: int) -> list[dict[str, str]]:
    local_path = str(source.get("path") or "").strip()
    if local_path:
        raw_html = read_text_resource(path=local_path)
    else:
        search_template = str(source.get("search_url_template") or DEFAULT_SEARCH_URL).strip()
        query = str(source.get("query") or "").strip()
        if not query:
            raise ValueError("web_search source requires query")
        search_url = search_template.format(query=urllib.parse.quote_plus(query))
        raw_html = request_bytes(search_url, timeout_seconds, accept="text/html,application/xhtml+xml").decode(
            "utf-8", errors="replace"
        )

    entries: list[dict[str, str]] = []
    for match in re.finditer(r'<a[^>]+href="([^"]+)"[^>]*>(.*?)</a>', raw_html, flags=re.IGNORECASE | re.DOTALL):
        href = normalize_text(html.unescape(match.group(1)))
        title = strip_html(match.group(2))
        if not href or not title:
            continue
        if href.startswith("/") or href.startswith("#"):
            continue
        entries.append(
            {
                "entry_id": href,
                "title": title,
                "url": href,
                "published_at": "",
                "summary": normalize_text(source.get("query") or ""),
            }
        )
    return entries


def parse_vtt(text: str) -> str:
    lines: list[str] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line == "WEBVTT":
            continue
        if re.match(r"^\d+$", line):
            continue
        if "-->" in line:
            continue
        if line.startswith("NOTE") or line.startswith("STYLE"):
            continue
        line = re.sub(r"<[^>]+>", " ", line)
        line = normalize_text(html.unescape(line))
        if line:
            lines.append(line)
    return normalize_text(" ".join(lines))


def parse_srt(text: str) -> str:
    lines: list[str] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if re.match(r"^\d+$", line):
            continue
        if "-->" in line:
            continue
        line = normalize_text(html.unescape(re.sub(r"<[^>]+>", " ", line)))
        if line:
            lines.append(line)
    return normalize_text(" ".join(lines))


def transcript_to_text(text: str, extension_hint: str = "") -> str:
    hint = extension_hint.lower()
    if hint.endswith(".vtt"):
        return parse_vtt(text)
    if hint.endswith(".srt"):
        return parse_srt(text)
    if text.lstrip().startswith("WEBVTT"):
        return parse_vtt(text)
    if "-->" in text:
        return parse_srt(text)
    return normalize_text(text)


def excerpt_text(text: str, limit: int = 500) -> str:
    normalized = normalize_text(text)
    if len(normalized) <= limit:
        return normalized
    return normalized[: max(0, limit - 3)].rstrip() + "..."


def collect_direct_transcript(source: dict[str, Any], timeout_seconds: int) -> list[dict[str, str]]:
    transcript_path = str(source.get("transcript_path") or source.get("path") or "").strip()
    transcript_url = str(source.get("transcript_url") or source.get("url") or "").strip()
    transcript_text = read_text_resource(transcript_path, transcript_url, timeout_seconds)
    extension_hint = transcript_path or transcript_url
    plain_text = transcript_to_text(transcript_text, extension_hint)
    title = normalize_text(source.get("title") or source.get("label") or source.get("id") or "media transcript")
    return [
        {
            "entry_id": title,
            "title": title,
            "url": transcript_url,
            "published_at": normalize_text(source.get("published_at") or ""),
            "summary": excerpt_text(plain_text),
        }
    ]


def collect_youtube_transcript(source: dict[str, Any], timeout_seconds: int) -> list[dict[str, str]]:
    video_url = str(source.get("url") or "").strip()
    if not video_url:
        raise ValueError("youtube_transcript source requires url")
    with tempfile.TemporaryDirectory(prefix="codex-research-ytdlp-") as temp_dir:
        metadata_command = ["yt-dlp", "--dump-single-json", "--skip-download", video_url]
        metadata_result = subprocess.run(
            metadata_command,
            check=True,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
        )
        metadata = json.loads(metadata_result.stdout or "{}")

        output_template = os.path.join(temp_dir, "capture")
        subtitle_command = [
            "yt-dlp",
            "--skip-download",
            "--write-auto-sub",
            "--write-sub",
            "--sub-langs",
            str(source.get("subtitle_languages") or "en.*,en"),
            "--sub-format",
            "vtt",
            "--output",
            output_template,
            video_url,
        ]
        subprocess.run(subtitle_command, check=True, capture_output=True, text=True, timeout=timeout_seconds)

        subtitle_files = sorted(
            file_name
            for file_name in os.listdir(temp_dir)
            if file_name.lower().endswith(".vtt") or file_name.lower().endswith(".srt")
        )
        if not subtitle_files:
            raise ValueError("yt-dlp did not produce subtitles for the video")
        subtitle_path = os.path.join(temp_dir, subtitle_files[0])
        transcript_text = read_text_resource(path=subtitle_path)
        plain_text = transcript_to_text(transcript_text, subtitle_path)
        published_at = normalize_text(metadata.get("upload_date") or "")
        if re.fullmatch(r"\d{8}", published_at):
            published_at = f"{published_at[:4]}-{published_at[4:6]}-{published_at[6:]}T00:00:00Z"
        return [
            {
                "entry_id": normalize_text(metadata.get("id") or video_url),
                "title": normalize_text(metadata.get("title") or source.get("label") or video_url),
                "url": normalize_text(metadata.get("webpage_url") or video_url),
                "published_at": published_at,
                "summary": excerpt_text(plain_text),
            }
        ]


def signal_id(source_id: str, entry: dict[str, str]) -> str:
    seed = "||".join(
        [
            source_id,
            str(entry.get("entry_id") or ""),
            str(entry.get("url") or ""),
            str(entry.get("title") or ""),
        ]
    )
    return hashlib.sha256(seed.encode("utf-8")).hexdigest()[:20]


def build_signal(source: dict[str, Any], entry: dict[str, str], freshness_window_seconds: int, fetched_at: str) -> dict[str, Any]:
    published_dt = parse_datetime(entry.get("published_at"))
    age_seconds = (
        max(int((now_utc() - published_dt).total_seconds()), 0) if isinstance(published_dt, datetime) else freshness_window_seconds
    )
    source_id = str(source.get("id") or "external-source").strip()
    source_label = normalize_text(source.get("label") or source_id)
    task_hint = normalize_text(source.get("task_hint") or "")
    title = normalize_text(entry.get("title") or source_label)
    signal_hash = signal_id(source_id, entry)
    return {
        "id": signal_hash,
        "source_id": source_id,
        "source_label": source_label,
        "topic": normalize_text(source.get("topic") or "external_research"),
        "category": normalize_text(source.get("category") or "code_quality") or "code_quality",
        "kind": normalize_text(source.get("kind") or "feed"),
        "title": title,
        "url": normalize_text(entry.get("url") or ""),
        "published_at": format_datetime(published_dt),
        "summary": normalize_text(entry.get("summary") or ""),
        "task_hint": task_hint,
        "fresh": age_seconds <= freshness_window_seconds,
        "age_seconds": age_seconds,
        "fetched_at": fetched_at,
        "source_task_id": f"external-signal::{source_id}::{signal_hash}",
        "slug": slugify(title)[:48],
    }


def previous_signals_by_source(existing: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for signal in existing.get("signals", []):
        if not isinstance(signal, dict):
            continue
        source_id = str(signal.get("source_id") or "").strip()
        if not source_id:
            continue
        grouped.setdefault(source_id, []).append(signal)
    return grouped


def snapshot_is_fresh(existing: dict[str, Any], cooldown_seconds: int) -> bool:
    updated_at = parse_datetime(existing.get("updated_at"))
    if updated_at is None:
        return False
    return max(int((now_utc() - updated_at).total_seconds()), 0) < cooldown_seconds


def collect_entries_for_source(source: dict[str, Any], timeout_seconds: int) -> list[dict[str, str]]:
    kind = normalize_text(source.get("kind") or "atom").lower()
    if kind in {"atom", "rss", "feed"}:
        return parse_feed(read_bytes(source, timeout_seconds))
    if kind == "web_search":
        return parse_web_search_results(source, timeout_seconds)
    if kind == "media_transcript":
        return collect_direct_transcript(source, timeout_seconds)
    if kind == "youtube_transcript":
        return collect_youtube_transcript(source, max(timeout_seconds, 30))
    raise ValueError(f"unsupported external signal kind: {kind}")


def refresh_signals(sources_path: str, output_path: str) -> dict[str, Any]:
    config = read_json(
        sources_path,
        {
            "auto_refresh": False,
            "refresh_cooldown_seconds": DEFAULT_REFRESH_COOLDOWN_SECONDS,
            "freshness_window_seconds": DEFAULT_FRESHNESS_WINDOW_SECONDS,
            "request_timeout_seconds": DEFAULT_REQUEST_TIMEOUT_SECONDS,
            "sources": [],
        },
    )
    existing = read_json(output_path, {"signals": [], "errors": []})
    auto_refresh = config.get("auto_refresh") is True
    cooldown_seconds = max(0, safe_int(config.get("refresh_cooldown_seconds"), DEFAULT_REFRESH_COOLDOWN_SECONDS))
    freshness_window_seconds = max(60, safe_int(config.get("freshness_window_seconds"), DEFAULT_FRESHNESS_WINDOW_SECONDS))
    timeout_seconds = max(1, safe_int(config.get("request_timeout_seconds"), DEFAULT_REQUEST_TIMEOUT_SECONDS))
    sources = [source for source in config.get("sources", []) if isinstance(source, dict) and source.get("enabled", True) is not False]

    if not auto_refresh:
        return existing
    if snapshot_is_fresh(existing, cooldown_seconds):
        return existing

    fetched_at = now_utc_text()
    previous_by_source = previous_signals_by_source(existing)
    signals: list[dict[str, Any]] = []
    errors: list[dict[str, Any]] = []

    for source in sources:
        source_id = str(source.get("id") or "").strip() or "external-source"
        max_items = max(1, safe_int(source.get("max_items"), 1))
        try:
            entries = collect_entries_for_source(source, timeout_seconds)
            parsed_signals = [
                build_signal(source, entry, freshness_window_seconds, fetched_at)
                for entry in entries[:max_items]
                if normalize_text(entry.get("title") or entry.get("url") or entry.get("entry_id"))
            ]
            signals.extend(parsed_signals)
        except Exception as exc:
            reused = previous_by_source.get(source_id, [])
            signals.extend(reused)
            errors.append(
                {
                    "source_id": source_id,
                    "message": normalize_text(exc),
                    "reused_previous": bool(reused),
                    "at": fetched_at,
                }
            )

    signals.sort(key=lambda item: (str(item.get("published_at") or ""), str(item.get("id") or "")), reverse=True)
    payload = {
        "updated_at": fetched_at,
        "auto_refresh": auto_refresh,
        "source_count": len(sources),
        "signal_count": len(signals),
        "signals": signals,
        "errors": errors,
    }
    write_json(output_path, payload)
    return payload


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: external_signals.py <sources.json> <external-signals.json>", file=sys.stderr)
        return 2

    payload = refresh_signals(sys.argv[1], sys.argv[2])
    print(
        json.dumps(
            {
                "updated_at": payload.get("updated_at", ""),
                "auto_refresh": payload.get("auto_refresh", False),
                "signal_count": payload.get("signal_count", 0),
                "error_count": len(payload.get("errors", [])),
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

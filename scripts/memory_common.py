#!/usr/bin/env python3
from __future__ import annotations

import json
import math
import os
import re
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Sequence

try:
    from sentence_transformers import SentenceTransformer
except Exception:  # pragma: no cover - dependency bootstrap fallback
    SentenceTransformer = None


DEFAULT_MODEL = os.environ.get("MEMORY_MODEL", "all-MiniLM-L6-v2")


@dataclass
class Chunk:
    source: str
    kind: str
    chunk_index: int
    content: str


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def init_db(connection: sqlite3.Connection) -> None:
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS memory_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source TEXT NOT NULL,
            kind TEXT NOT NULL,
            chunk_index INTEGER NOT NULL,
            content TEXT NOT NULL,
            embedding TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """
    )
    connection.execute("CREATE INDEX IF NOT EXISTS idx_memory_source ON memory_entries(source)")
    connection.execute("CREATE INDEX IF NOT EXISTS idx_memory_kind ON memory_entries(kind)")
    connection.commit()


def split_text_into_chunks(text: str, max_chars: int = 500) -> list[str]:
    paragraphs = [part.strip() for part in re.split(r"\n\s*\n", text) if part.strip()]
    if not paragraphs:
        paragraphs = [line.strip() for line in text.splitlines() if line.strip()]

    chunks: list[str] = []
    current: list[str] = []
    current_length = 0
    for paragraph in paragraphs:
        paragraph_length = len(paragraph)
        if current and current_length + paragraph_length + 2 > max_chars:
            chunks.append("\n\n".join(current))
            current = [paragraph]
            current_length = paragraph_length
        else:
            current.append(paragraph)
            current_length += paragraph_length + 2

    if current:
        chunks.append("\n\n".join(current))

    return chunks


def detect_kind(path: Path) -> str:
    if path.suffix == ".log":
        return "log"
    if path.suffix == ".md":
        return "markdown"
    return "text"


def build_chunks(paths: Sequence[str], max_chars: int = 500) -> list[Chunk]:
    chunks: list[Chunk] = []
    for source in paths:
        path = Path(source)
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8", errors="ignore").strip()
        if not text:
            continue
        kind = detect_kind(path)
        for index, chunk in enumerate(split_text_into_chunks(text, max_chars=max_chars), start=1):
            chunks.append(Chunk(source=str(path), kind=kind, chunk_index=index, content=chunk))
    return chunks


def load_model(model_name: str = DEFAULT_MODEL):
    if SentenceTransformer is None:
        return None
    try:
        return SentenceTransformer(model_name)
    except Exception:
        return None


def embed_texts(texts: Sequence[str], model_name: str = DEFAULT_MODEL) -> tuple[list[list[float] | None], bool]:
    model = load_model(model_name)
    if model is None:
        return [None for _ in texts], False
    embeddings = model.encode(list(texts), normalize_embeddings=True).tolist()
    return embeddings, True


def embed_query(text: str, model_name: str = DEFAULT_MODEL) -> list[float] | None:
    model = load_model(model_name)
    if model is None:
        return None
    return model.encode(text, normalize_embeddings=True).tolist()


def lexical_score(query: str, content: str) -> float:
    query_tokens = set(re.findall(r"[a-z0-9]+", query.lower()))
    content_tokens = set(re.findall(r"[a-z0-9]+", content.lower()))
    if not query_tokens or not content_tokens:
        return 0.0
    overlap = len(query_tokens & content_tokens)
    return overlap / max(len(query_tokens), 1)


def cosine_similarity(left: Sequence[float], right: Sequence[float]) -> float:
    if not left or not right:
        return 0.0
    numerator = sum(l * r for l, r in zip(left, right))
    left_norm = math.sqrt(sum(l * l for l in left))
    right_norm = math.sqrt(sum(r * r for r in right))
    if not left_norm or not right_norm:
        return 0.0
    return numerator / (left_norm * right_norm)


def parse_embedding(value: str) -> list[float]:
    if not value:
        return []
    return json.loads(value)


def serialize_embedding(value: Sequence[float] | None) -> str:
    return json.dumps(list(value or []))

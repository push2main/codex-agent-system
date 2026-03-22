#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sqlite3
from pathlib import Path

from memory_common import build_chunks, embed_texts, init_db, serialize_embedding, utc_now


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Index Codex memory files into SQLite.")
    parser.add_argument("--db", required=True, help="Path to the SQLite database.")
    parser.add_argument("--source", action="append", default=[], help="Source file to index.")
    parser.add_argument("--max-chars", type=int, default=500, help="Maximum chunk size.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    db_path = Path(args.db)
    db_path.parent.mkdir(parents=True, exist_ok=True)

    chunks = build_chunks(args.source, max_chars=args.max_chars)
    texts = [chunk.content for chunk in chunks]
    embeddings, using_model = embed_texts(texts)

    connection = sqlite3.connect(db_path)
    init_db(connection)

    for source in args.source:
        connection.execute("DELETE FROM memory_entries WHERE source = ?", (str(Path(source)),))

    connection.executemany(
        """
        INSERT INTO memory_entries (source, kind, chunk_index, content, embedding, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        [
            (
                chunk.source,
                chunk.kind,
                chunk.chunk_index,
                chunk.content,
                serialize_embedding(embedding),
                utc_now(),
            )
            for chunk, embedding in zip(chunks, embeddings)
        ],
    )
    connection.commit()
    connection.close()

    mode = "sentence-transformers" if using_model else "lexical-fallback"
    print(f"Indexed {len(chunks)} chunks into {db_path} using {mode}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

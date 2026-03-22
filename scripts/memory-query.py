#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path

from memory_common import cosine_similarity, embed_query, lexical_score, parse_embedding


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Query Codex memory for relevant context.")
    parser.add_argument("query", help="Task or prompt to search for.")
    parser.add_argument("--db", required=True, help="Path to the SQLite database.")
    parser.add_argument("--limit", type=int, default=3, help="Maximum number of matches.")
    parser.add_argument("--json", action="store_true", help="Return JSON instead of text.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    db_path = Path(args.db)
    if not db_path.exists():
        if args.json:
            print("[]")
        return 0

    connection = sqlite3.connect(db_path)
    rows = connection.execute(
        "SELECT source, kind, chunk_index, content, embedding, updated_at FROM memory_entries"
    ).fetchall()
    connection.close()

    query_embedding = embed_query(args.query)
    results: list[dict[str, object]] = []
    for source, kind, chunk_index, content, embedding, updated_at in rows:
        vector = parse_embedding(embedding)
        if query_embedding and vector:
            score = cosine_similarity(query_embedding, vector)
        else:
            score = lexical_score(args.query, content)
        results.append(
            {
                "source": source,
                "kind": kind,
                "chunk_index": chunk_index,
                "content": content,
                "score": round(float(score), 4),
                "updated_at": updated_at,
            }
        )

    results.sort(key=lambda item: item["score"], reverse=True)
    limited = [item for item in results if item["score"] > 0][: args.limit]

    if args.json:
        print(json.dumps(limited, indent=2))
        return 0

    for index, item in enumerate(limited, start=1):
        print(f"[{index}] {item['source']} score={item['score']}")
        print(item["content"])
        if index != len(limited):
            print()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

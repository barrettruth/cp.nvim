#!/usr/bin/env python3
"""Simulate exactly what the CLI does."""
import asyncio
import json
import os
import sys

sys.path.insert(0, ".")

SOURCE = '#include <bits/stdc++.h>\nusing namespace std;\nint main() { cout << 42; }\n'


async def main():
    from scrapers.codeforces import CodeforcesScraper
    from scrapers.language_ids import get_language_id

    scraper = CodeforcesScraper()
    credentials = json.loads(os.environ.get("CP_CREDENTIALS", "{}"))
    language_id = get_language_id("codeforces", "cpp") or "89"

    print(f"source length: {len(SOURCE)}", flush=True)
    print(f"credentials keys: {list(credentials.keys())}", flush=True)
    print(f"language_id: {language_id}", flush=True)

    result = await scraper.submit("1933", "a", SOURCE, language_id, credentials)
    print(result.model_dump_json(indent=2), flush=True)


if __name__ == "__main__":
    asyncio.run(main())

#!/usr/bin/env python3
"""Call _submit_headless directly, no asyncio."""
import json
import os
import sys

sys.path.insert(0, ".")

from scrapers.codeforces import _submit_headless

creds = json.loads(os.environ.get("CP_CREDENTIALS", "{}"))
result = _submit_headless("1933", "a", "int main(){}", "89", creds)
print(result.model_dump_json(indent=2))

#!/usr/bin/env python3

import asyncio
import json
import re
from typing import Any

import httpx
from curl_cffi import requests as curl_requests

from .base import BaseScraper
from .models import (
    ContestListResult,
    ContestSummary,
    MetadataResult,
    ProblemSummary,
    TestCase,
)

BASE_URL = "https://www.codechef.com"
API_CONTESTS_ALL = "/api/list/contests/all"
API_CONTEST = "/api/contests/{contest_id}"
API_PROBLEM = "/api/contests/{contest_id}/problems/{problem_id}"
PROBLEM_URL = "https://www.codechef.com/problems/{problem_id}"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
}
TIMEOUT_S = 15.0
CONNECTIONS = 8
MEMORY_LIMIT_RE = re.compile(
    r"Memory\s+[Ll]imit.*?([0-9.]+)\s*(MB|GB)", re.IGNORECASE | re.DOTALL
)


async def fetch_json(client: httpx.AsyncClient, path: str) -> dict:
    r = await client.get(BASE_URL + path, headers=HEADERS, timeout=TIMEOUT_S)
    r.raise_for_status()
    return r.json()


def _extract_memory_limit(html: str) -> float:
    m = MEMORY_LIMIT_RE.search(html)
    if not m:
        return 256.0
    value = float(m.group(1))
    unit = m.group(2).upper()
    if unit == "GB":
        return value * 1024.0
    return value


def _fetch_html_sync(url: str) -> str:
    response = curl_requests.get(url, impersonate="chrome", timeout=TIMEOUT_S)
    response.raise_for_status()
    return response.text


class CodeChefScraper(BaseScraper):
    @property
    def platform_name(self) -> str:
        return "codechef"

    async def scrape_contest_metadata(self, contest_id: str) -> MetadataResult:
        try:
            async with httpx.AsyncClient() as client:
                data = await fetch_json(
                    client, API_CONTEST.format(contest_id=contest_id)
                )
            if not data.get("problems"):
                return self._metadata_error(
                    f"No problems found for contest {contest_id}"
                )
            problems = []
            for problem_code, problem_data in data["problems"].items():
                if problem_data.get("category_name") == "main":
                    problems.append(
                        ProblemSummary(
                            id=problem_code,
                            name=problem_data.get("name", problem_code),
                        )
                    )
            return MetadataResult(
                success=True,
                error="",
                contest_id=contest_id,
                problems=problems,
                url=f"{BASE_URL}/{contest_id}",
            )
        except Exception as e:
            return self._metadata_error(f"Failed to fetch contest {contest_id}: {e}")

    async def scrape_contest_list(self) -> ContestListResult:
        async with httpx.AsyncClient() as client:
            try:
                data = await fetch_json(client, API_CONTESTS_ALL)
            except httpx.HTTPStatusError as e:
                return self._contests_error(f"Failed to fetch contests: {e}")
            all_contests = data.get("future_contests", []) + data.get(
                "past_contests", []
            )
            max_num = 0
            for contest in all_contests:
                contest_code = contest.get("contest_code", "")
                if contest_code.startswith("START"):
                    match = re.match(r"START(\d+)", contest_code)
                    if match:
                        num = int(match.group(1))
                        max_num = max(max_num, num)
            if max_num == 0:
                return self._contests_error("No Starters contests found")
            contests = []
            sem = asyncio.Semaphore(CONNECTIONS)

            async def fetch_divisions(i: int) -> list[ContestSummary]:
                parent_id = f"START{i}"
                async with sem:
                    try:
                        parent_data = await fetch_json(
                            client, API_CONTEST.format(contest_id=parent_id)
                        )
                    except Exception as e:
                        import sys

                        print(f"Error fetching {parent_id}: {e}", file=sys.stderr)
                        return []
                child_contests = parent_data.get("child_contests", {})
                if not child_contests:
                    return []
                base_name = f"Starters {i}"
                divisions = []
                for div_key, div_data in child_contests.items():
                    div_code = div_data.get("contest_code", "")
                    div_num = div_data.get("div", {}).get("div_number", "")
                    if div_code and div_num:
                        divisions.append(
                            ContestSummary(
                                id=div_code,
                                name=base_name,
                                display_name=f"{base_name} (Div. {div_num})",
                            )
                        )
                return divisions

            tasks = [fetch_divisions(i) for i in range(1, max_num + 1)]
            for coro in asyncio.as_completed(tasks):
                divisions = await coro
                contests.extend(divisions)
        return ContestListResult(success=True, error="", contests=contests)

    async def stream_tests_for_category_async(self, category_id: str) -> None:
        async with httpx.AsyncClient(
            limits=httpx.Limits(max_connections=CONNECTIONS)
        ) as client:
            try:
                contest_data = await fetch_json(
                    client, API_CONTEST.format(contest_id=category_id)
                )
            except Exception as e:
                print(
                    json.dumps(
                        {"error": f"Failed to fetch contest {category_id}: {str(e)}"}
                    ),
                    flush=True,
                )
                return
            all_problems = contest_data.get("problems", {})
            if not all_problems:
                print(
                    json.dumps(
                        {"error": f"No problems found for contest {category_id}"}
                    ),
                    flush=True,
                )
                return
            problems = {
                code: data
                for code, data in all_problems.items()
                if data.get("category_name") == "main"
            }
            if not problems:
                print(
                    json.dumps(
                        {"error": f"No main problems found for contest {category_id}"}
                    ),
                    flush=True,
                )
                return
            sem = asyncio.Semaphore(CONNECTIONS)

            async def run_one(problem_code: str) -> dict[str, Any]:
                async with sem:
                    try:
                        problem_data = await fetch_json(
                            client,
                            API_PROBLEM.format(
                                contest_id=category_id, problem_id=problem_code
                            ),
                        )
                        sample_tests = (
                            problem_data.get("problemComponents", {}).get(
                                "sampleTestCases", []
                            )
                            or []
                        )
                        tests = [
                            TestCase(
                                input=t.get("input", "").strip(),
                                expected=t.get("output", "").strip(),
                            )
                            for t in sample_tests
                            if not t.get("isDeleted", False)
                        ]
                        time_limit_str = problem_data.get("max_timelimit", "1")
                        timeout_ms = int(float(time_limit_str) * 1000)
                        problem_url = PROBLEM_URL.format(problem_id=problem_code)
                        loop = asyncio.get_event_loop()
                        html = await loop.run_in_executor(
                            None, _fetch_html_sync, problem_url
                        )
                        memory_mb = _extract_memory_limit(html)
                        interactive = False
                    except Exception:
                        tests = []
                        timeout_ms = 1000
                        memory_mb = 256.0
                        interactive = False
                    combined_input = "\n".join(t.input for t in tests) if tests else ""
                    combined_expected = (
                        "\n".join(t.expected for t in tests) if tests else ""
                    )
                    return {
                        "problem_id": problem_code,
                        "combined": {
                            "input": combined_input,
                            "expected": combined_expected,
                        },
                        "tests": [
                            {"input": t.input, "expected": t.expected} for t in tests
                        ],
                        "timeout_ms": timeout_ms,
                        "memory_mb": memory_mb,
                        "interactive": interactive,
                        "multi_test": False,
                    }

            tasks = [run_one(problem_code) for problem_code in problems.keys()]
            for coro in asyncio.as_completed(tasks):
                payload = await coro
                print(json.dumps(payload), flush=True)


if __name__ == "__main__":
    CodeChefScraper().run_cli()

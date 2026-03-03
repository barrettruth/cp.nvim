#!/usr/bin/env python3

import asyncio
import io
import json
import re
import zipfile

import httpx

from .base import BaseScraper
from .models import (
    ContestListResult,
    ContestSummary,
    MetadataResult,
    ProblemSummary,
    SubmitResult,
    TestCase,
)

BASE_URL = "https://open.kattis.com"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
}
TIMEOUT_S = 15.0
CONNECTIONS = 8

TIME_RE = re.compile(
    r"CPU Time limit</span>\s*<span[^>]*>\s*(\d+)\s*seconds?\s*</span>",
    re.DOTALL,
)
MEM_RE = re.compile(
    r"Memory limit</span>\s*<span[^>]*>\s*(\d+)\s*MB\s*</span>",
    re.DOTALL,
)
LAST_PAGE_RE = re.compile(r"\bpage=(\d+)")


async def _fetch_text(client: httpx.AsyncClient, url: str) -> str:
    r = await client.get(url, headers=HEADERS, timeout=TIMEOUT_S)
    r.raise_for_status()
    return r.text


async def _fetch_bytes(client: httpx.AsyncClient, url: str) -> bytes:
    r = await client.get(url, headers=HEADERS, timeout=TIMEOUT_S)
    r.raise_for_status()
    return r.content


def _parse_limits(html: str) -> tuple[int, int]:
    tm = TIME_RE.search(html)
    mm = MEM_RE.search(html)
    timeout_ms = int(tm.group(1)) * 1000 if tm else 1000
    memory_mb = int(mm.group(1)) if mm else 1024
    return timeout_ms, memory_mb


def _parse_samples_html(html: str) -> list[TestCase]:
    tests: list[TestCase] = []
    tables = re.finditer(r'<table\s+class="sample"[^>]*>.*?</table>', html, re.DOTALL)
    for table_match in tables:
        table_html = table_match.group(0)
        pres = re.findall(r"<pre>(.*?)</pre>", table_html, re.DOTALL)
        if len(pres) >= 2:
            inp = pres[0].strip()
            out = pres[1].strip()
            tests.append(TestCase(input=inp, expected=out))
    return tests


def _parse_samples_zip(data: bytes) -> list[TestCase]:
    try:
        zf = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile:
        return []
    inputs: dict[str, str] = {}
    outputs: dict[str, str] = {}
    for name in zf.namelist():
        content = zf.read(name).decode("utf-8").strip()
        if name.endswith(".in"):
            key = name[: -len(".in")]
            inputs[key] = content
        elif name.endswith(".ans"):
            key = name[: -len(".ans")]
            outputs[key] = content
    tests: list[TestCase] = []
    for key in sorted(set(inputs) & set(outputs)):
        tests.append(TestCase(input=inputs[key], expected=outputs[key]))
    return tests


def _is_interactive(html: str) -> bool:
    return "This is an interactive problem" in html


def _parse_problem_rows(html: str) -> list[tuple[str, str]]:
    seen: set[str] = set()
    out: list[tuple[str, str]] = []
    for m in re.finditer(
        r'<td\s+class="[^"]*">\s*<a\s+href="/problems/([a-z0-9]+)"\s*>([^<]+)</a>',
        html,
    ):
        pid = m.group(1)
        name = m.group(2).strip()
        if pid not in seen:
            seen.add(pid)
            out.append((pid, name))
    return out


def _parse_last_page(html: str) -> int:
    nums = [int(m.group(1)) for m in LAST_PAGE_RE.finditer(html)]
    return max(nums) if nums else 0


class KattisScraper(BaseScraper):
    @property
    def platform_name(self) -> str:
        return "kattis"

    async def scrape_contest_metadata(self, contest_id: str) -> MetadataResult:
        try:
            async with httpx.AsyncClient() as client:
                html = await _fetch_text(client, f"{BASE_URL}/problems/{contest_id}")
            timeout_ms, memory_mb = _parse_limits(html)
            title_m = re.search(r"<title>([^<]+)</title>", html)
            name = (
                title_m.group(1).split("\u2013")[0].strip() if title_m else contest_id
            )
            return MetadataResult(
                success=True,
                error="",
                contest_id=contest_id,
                problems=[ProblemSummary(id=contest_id, name=name)],
                url=f"{BASE_URL}/problems/%s",
            )
        except Exception as e:
            return self._metadata_error(str(e))

    async def scrape_contest_list(self) -> ContestListResult:
        try:
            async with httpx.AsyncClient(
                limits=httpx.Limits(max_connections=CONNECTIONS)
            ) as client:
                first_html = await _fetch_text(
                    client, f"{BASE_URL}/problems?page=0&order=problem_difficulty"
                )
                last = _parse_last_page(first_html)
                rows = _parse_problem_rows(first_html)

                sem = asyncio.Semaphore(CONNECTIONS)

                async def fetch_page(page: int) -> list[tuple[str, str]]:
                    async with sem:
                        html = await _fetch_text(
                            client,
                            f"{BASE_URL}/problems?page={page}&order=problem_difficulty",
                        )
                        return _parse_problem_rows(html)

                tasks = [fetch_page(p) for p in range(1, last + 1)]
                for coro in asyncio.as_completed(tasks):
                    rows.extend(await coro)

            seen: set[str] = set()
            contests: list[ContestSummary] = []
            for pid, name in rows:
                if pid not in seen:
                    seen.add(pid)
                    contests.append(
                        ContestSummary(id=pid, name=name, display_name=name)
                    )
            if not contests:
                return self._contests_error("No problems found")
            return ContestListResult(success=True, error="", contests=contests)
        except Exception as e:
            return self._contests_error(str(e))

    async def stream_tests_for_category_async(self, category_id: str) -> None:
        async with httpx.AsyncClient(
            limits=httpx.Limits(max_connections=CONNECTIONS)
        ) as client:
            try:
                html = await _fetch_text(client, f"{BASE_URL}/problems/{category_id}")
            except Exception:
                return

            timeout_ms, memory_mb = _parse_limits(html)
            interactive = _is_interactive(html)

            tests: list[TestCase] = []
            try:
                zip_data = await _fetch_bytes(
                    client,
                    f"{BASE_URL}/problems/{category_id}/file/statement/samples.zip",
                )
                tests = _parse_samples_zip(zip_data)
            except Exception:
                tests = _parse_samples_html(html)

            combined_input = "\n".join(t.input for t in tests) if tests else ""
            combined_expected = "\n".join(t.expected for t in tests) if tests else ""

            print(
                json.dumps(
                    {
                        "problem_id": category_id,
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
                ),
                flush=True,
            )

    async def submit(
        self,
        contest_id: str,
        problem_id: str,
        source_code: str,
        language_id: str,
        credentials: dict[str, str],
    ) -> SubmitResult:
        return SubmitResult(
            success=False,
            error="Kattis submit not yet implemented",
            submission_id="",
            verdict="",
        )


if __name__ == "__main__":
    KattisScraper().run_cli()

#!/usr/bin/env python3

import asyncio
import json
import re
from typing import Any, cast

import httpx

from .base import BaseScraper
from .timeouts import HTTP_TIMEOUT
from .models import (
    ContestListResult,
    ContestSummary,
    MetadataResult,
    ProblemSummary,
    SubmitResult,
    TestCase,
)

BASE_URL = "http://www.usaco.org"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
}
CONNECTIONS = 4

MONTHS = [
    "dec",
    "jan",
    "feb",
    "mar",
    "open",
]

DIVISION_HEADING_RE = re.compile(
    r"<h2>.*?USACO\s+(\d{4})\s+(\w+)\s+Contest,\s+(\w+)\s*</h2>",
    re.IGNORECASE,
)
PROBLEM_BLOCK_RE = re.compile(
    r"<b>([^<]+)</b>\s*<br\s*/?>.*?"
    r"viewproblem2&cpid=(\d+)",
    re.DOTALL,
)
SAMPLE_IN_RE = re.compile(r"<pre\s+class=['\"]in['\"]>(.*?)</pre>", re.DOTALL)
SAMPLE_OUT_RE = re.compile(r"<pre\s+class=['\"]out['\"]>(.*?)</pre>", re.DOTALL)
TIME_NOTE_RE = re.compile(
    r"time\s+limit\s+(?:for\s+this\s+problem\s+is\s+)?(\d+)s",
    re.IGNORECASE,
)
MEMORY_NOTE_RE = re.compile(
    r"memory\s+limit\s+(?:for\s+this\s+problem\s+is\s+)?(\d+)\s*MB",
    re.IGNORECASE,
)
RESULTS_PAGE_RE = re.compile(
    r'href="index\.php\?page=([a-z]+\d{2,4}results)"',
    re.IGNORECASE,
)


async def _fetch_text(client: httpx.AsyncClient, url: str) -> str:
    r = await client.get(
        url, headers=HEADERS, timeout=HTTP_TIMEOUT, follow_redirects=True
    )
    r.raise_for_status()
    return r.text


def _parse_results_page(html: str) -> dict[str, list[tuple[str, str]]]:
    sections: dict[str, list[tuple[str, str]]] = {}
    current_div: str | None = None

    parts = re.split(r"(<h2>.*?</h2>)", html, flags=re.DOTALL)
    for part in parts:
        heading_m = DIVISION_HEADING_RE.search(part)
        if heading_m:
            current_div = heading_m.group(3).lower()
            sections.setdefault(current_div, [])
            continue
        if current_div is not None:
            for m in PROBLEM_BLOCK_RE.finditer(part):
                name = m.group(1).strip()
                cpid = m.group(2)
                sections[current_div].append((cpid, name))

    return sections


def _parse_contest_id(contest_id: str) -> tuple[str, str]:
    parts = contest_id.rsplit("_", 1)
    if len(parts) != 2:
        return contest_id, ""
    return parts[0], parts[1].lower()


def _results_page_slug(month_year: str) -> str:
    return f"{month_year}results"


def _parse_problem_page(html: str) -> dict[str, Any]:
    inputs = SAMPLE_IN_RE.findall(html)
    outputs = SAMPLE_OUT_RE.findall(html)
    tests: list[TestCase] = []
    for inp, out in zip(inputs, outputs):
        tests.append(
            TestCase(
                input=inp.strip().replace("\r", ""),
                expected=out.strip().replace("\r", ""),
            )
        )

    tm = TIME_NOTE_RE.search(html)
    mm = MEMORY_NOTE_RE.search(html)
    timeout_ms = int(tm.group(1)) * 1000 if tm else 4000
    memory_mb = int(mm.group(1)) if mm else 256

    interactive = "interactive problem" in html.lower()

    return {
        "tests": tests,
        "timeout_ms": timeout_ms,
        "memory_mb": memory_mb,
        "interactive": interactive,
    }


class USACOScraper(BaseScraper):
    @property
    def platform_name(self) -> str:
        return "usaco"

    async def scrape_contest_metadata(self, contest_id: str) -> MetadataResult:
        try:
            month_year, division = _parse_contest_id(contest_id)
            if not division:
                return self._metadata_error(
                    f"Invalid contest ID '{contest_id}'. "
                    "Expected format: <monthYY>_<division> (e.g. dec24_gold)"
                )

            slug = _results_page_slug(month_year)
            async with httpx.AsyncClient() as client:
                html = await _fetch_text(client, f"{BASE_URL}/index.php?page={slug}")
            sections = _parse_results_page(html)
            problems_raw = sections.get(division, [])
            if not problems_raw:
                return self._metadata_error(
                    f"No problems found for {contest_id} (division: {division})"
                )
            problems = [
                ProblemSummary(id=cpid, name=name) for cpid, name in problems_raw
            ]
            return MetadataResult(
                success=True,
                error="",
                contest_id=contest_id,
                problems=problems,
                url=f"{BASE_URL}/index.php?page=viewproblem2&cpid=%s",
            )
        except Exception as e:
            return self._metadata_error(str(e))

    async def scrape_contest_list(self) -> ContestListResult:
        try:
            async with httpx.AsyncClient(
                limits=httpx.Limits(max_connections=CONNECTIONS)
            ) as client:
                html = await _fetch_text(client, f"{BASE_URL}/index.php?page=contests")

                page_slugs: set[str] = set()
                for m in RESULTS_PAGE_RE.finditer(html):
                    page_slugs.add(m.group(1))

                recent_patterns = []
                for year in range(15, 27):
                    for month in MONTHS:
                        recent_patterns.append(f"{month}{year:02d}results")
                page_slugs.update(recent_patterns)

                contests: list[ContestSummary] = []
                sem = asyncio.Semaphore(CONNECTIONS)

                async def check_page(slug: str) -> list[ContestSummary]:
                    async with sem:
                        try:
                            page_html = await _fetch_text(
                                client, f"{BASE_URL}/index.php?page={slug}"
                            )
                        except Exception:
                            return []
                        sections = _parse_results_page(page_html)
                        if not sections:
                            return []
                        month_year = slug.replace("results", "")
                        out: list[ContestSummary] = []
                        for div in sections:
                            cid = f"{month_year}_{div}"
                            year_m = re.search(r"\d{2,4}", month_year)
                            month_m = re.search(r"[a-z]+", month_year)
                            year_str = year_m.group() if year_m else ""
                            month_str = month_m.group().capitalize() if month_m else ""
                            if len(year_str) == 2:
                                year_str = f"20{year_str}"
                            display = (
                                f"USACO {year_str} {month_str} - {div.capitalize()}"
                            )
                            out.append(
                                ContestSummary(id=cid, name=cid, display_name=display)
                            )
                        return out

                tasks = [check_page(slug) for slug in sorted(page_slugs)]
                for coro in asyncio.as_completed(tasks):
                    contests.extend(await coro)

            if not contests:
                return self._contests_error("No contests found")
            return ContestListResult(success=True, error="", contests=contests)
        except Exception as e:
            return self._contests_error(str(e))

    async def stream_tests_for_category_async(self, category_id: str) -> None:
        month_year, division = _parse_contest_id(category_id)
        if not division:
            return

        slug = _results_page_slug(month_year)
        async with httpx.AsyncClient(
            limits=httpx.Limits(max_connections=CONNECTIONS)
        ) as client:
            try:
                html = await _fetch_text(client, f"{BASE_URL}/index.php?page={slug}")
            except Exception:
                return

            sections = _parse_results_page(html)
            problems_raw = sections.get(division, [])
            if not problems_raw:
                return

            sem = asyncio.Semaphore(CONNECTIONS)

            async def run_one(cpid: str) -> dict[str, Any]:
                async with sem:
                    try:
                        problem_html = await _fetch_text(
                            client,
                            f"{BASE_URL}/index.php?page=viewproblem2&cpid={cpid}",
                        )
                        info = _parse_problem_page(problem_html)
                    except Exception:
                        info = {
                            "tests": [],
                            "timeout_ms": 4000,
                            "memory_mb": 256,
                            "interactive": False,
                        }

                    tests = cast(list[TestCase], info["tests"])
                    combined_input = "\n".join(t.input for t in tests) if tests else ""
                    combined_expected = (
                        "\n".join(t.expected for t in tests) if tests else ""
                    )

                    return {
                        "problem_id": cpid,
                        "combined": {
                            "input": combined_input,
                            "expected": combined_expected,
                        },
                        "tests": [
                            {"input": t.input, "expected": t.expected} for t in tests
                        ],
                        "timeout_ms": info["timeout_ms"],
                        "memory_mb": info["memory_mb"],
                        "interactive": info["interactive"],
                        "multi_test": False,
                    }

            tasks = [run_one(cpid) for cpid, _ in problems_raw]
            for coro in asyncio.as_completed(tasks):
                payload = await coro
                print(json.dumps(payload), flush=True)

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
            error="USACO submit not yet implemented",
            submission_id="",
            verdict="",
        )


if __name__ == "__main__":
    USACOScraper().run_cli()

#!/usr/bin/env python3

import asyncio
import json
import re
from typing import Any

import requests
from bs4 import BeautifulSoup, Tag
from curl_cffi import requests as curl_requests

from .base import BaseScraper
from .models import (
    ContestListResult,
    ContestSummary,
    MetadataResult,
    ProblemSummary,
    TestCase,
)

BASE_URL = "https://codeforces.com"
API_CONTEST_LIST_URL = f"{BASE_URL}/api/contest.list"
TIMEOUT_SECONDS = 30
HEADERS = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
}


def _text_from_pre(pre: Tag) -> str:
    return (
        pre.get_text(separator="\n", strip=False)
        .replace("\r", "")
        .replace("\xa0", " ")
        .strip()
    )


def _extract_limits(block: Tag) -> tuple[int, float]:
    tdiv = block.find("div", class_="time-limit")
    mdiv = block.find("div", class_="memory-limit")
    timeout_ms = 0
    memory_mb = 0.0
    if tdiv:
        ttxt = tdiv.get_text(" ", strip=True)
        ts = re.search(r"(\d+)\s*seconds?", ttxt)
        if ts:
            timeout_ms = int(ts.group(1)) * 1000
    if mdiv:
        mtxt = mdiv.get_text(" ", strip=True)
        ms = re.search(r"(\d+)\s*megabytes?", mtxt)
        if ms:
            memory_mb = float(ms.group(1))
    return timeout_ms, memory_mb


def _group_lines_by_id(pre: Tag) -> dict[int, list[str]]:
    groups: dict[int, list[str]] = {}
    for div in pre.find_all("div", class_="test-example-line"):
        cls = " ".join(div.get("class", []))
        m = re.search(r"\btest-example-line-(\d+)\b", cls)
        if not m:
            continue
        gid = int(m.group(1))
        groups.setdefault(gid, []).append(div.get_text("", strip=False))
    return groups


def _extract_title(block: Tag) -> tuple[str, str]:
    t = block.find("div", class_="title")
    if not t:
        return "", ""
    s = t.get_text(" ", strip=True)
    parts = s.split(".", 1)
    if len(parts) != 2:
        return "", s.strip()
    return parts[0].strip().upper(), parts[1].strip()


def _extract_samples(block: Tag) -> tuple[list[TestCase], bool]:
    st = block.find("div", class_="sample-test")
    if not st:
        return [], False

    input_pres: list[Tag] = [
        inp.find("pre")
        for inp in st.find_all("div", class_="input")
        if isinstance(inp, Tag) and inp.find("pre")
    ]
    output_pres: list[Tag] = [
        out.find("pre")
        for out in st.find_all("div", class_="output")
        if isinstance(out, Tag) and out.find("pre")
    ]
    input_pres = [p for p in input_pres if isinstance(p, Tag)]
    output_pres = [p for p in output_pres if isinstance(p, Tag)]

    has_grouped = any(
        p.find("div", class_="test-example-line") for p in input_pres + output_pres
    )
    if has_grouped:
        inputs_by_gid: dict[int, list[str]] = {}
        outputs_by_gid: dict[int, list[str]] = {}
        for p in input_pres:
            g = _group_lines_by_id(p)
            for k, v in g.items():
                inputs_by_gid.setdefault(k, []).extend(v)
        for p in output_pres:
            g = _group_lines_by_id(p)
            for k, v in g.items():
                outputs_by_gid.setdefault(k, []).extend(v)
        inputs_by_gid.pop(0, None)
        outputs_by_gid.pop(0, None)
        keys = sorted(set(inputs_by_gid.keys()) & set(outputs_by_gid.keys()))
        if keys:
            samples = [
                TestCase(
                    input="\n".join(inputs_by_gid[k]).strip(),
                    expected="\n".join(outputs_by_gid[k]).strip(),
                )
                for k in keys
            ]
            return samples, True

    inputs = [_text_from_pre(p) for p in input_pres]
    outputs = [_text_from_pre(p) for p in output_pres]
    n = min(len(inputs), len(outputs))
    return [TestCase(input=inputs[i], expected=outputs[i]) for i in range(n)], False


def _is_interactive(block: Tag) -> bool:
    ps = block.find("div", class_="problem-statement")
    txt = ps.get_text(" ", strip=True) if ps else block.get_text(" ", strip=True)
    return "This is an interactive problem" in txt


def _fetch_problems_html(contest_id: str) -> str:
    url = f"{BASE_URL}/contest/{contest_id}/problems"
    response = curl_requests.get(url, impersonate="chrome", timeout=TIMEOUT_SECONDS)
    response.raise_for_status()
    return response.text


def _parse_all_blocks(html: str) -> list[dict[str, Any]]:
    soup = BeautifulSoup(html, "html.parser")
    blocks = soup.find_all("div", class_="problem-statement")
    out: list[dict[str, Any]] = []
    for b in blocks:
        holder = b.find_parent("div", class_="problemindexholder")
        letter = (holder.get("problemindex") if holder else "").strip().upper()
        name = _extract_title(b)[1]
        if not letter:
            continue
        raw_samples, is_grouped = _extract_samples(b)
        timeout_ms, memory_mb = _extract_limits(b)
        interactive = _is_interactive(b)

        if is_grouped and raw_samples:
            combined_input = f"{len(raw_samples)}\n" + "\n".join(
                tc.input for tc in raw_samples
            )
            combined_expected = "\n".join(tc.expected for tc in raw_samples)
            individual_tests = [
                TestCase(input=f"1\n{tc.input}", expected=tc.expected)
                for tc in raw_samples
            ]
        else:
            combined_input = "\n".join(tc.input for tc in raw_samples)
            combined_expected = "\n".join(tc.expected for tc in raw_samples)
            individual_tests = raw_samples

        out.append(
            {
                "letter": letter,
                "name": name,
                "combined_input": combined_input,
                "combined_expected": combined_expected,
                "tests": individual_tests,
                "timeout_ms": timeout_ms,
                "memory_mb": memory_mb,
                "interactive": interactive,
                "multi_test": is_grouped,
            }
        )
    return out


def _scrape_contest_problems_sync(contest_id: str) -> list[ProblemSummary]:
    html = _fetch_problems_html(contest_id)
    blocks = _parse_all_blocks(html)
    problems: list[ProblemSummary] = []
    for b in blocks:
        pid = b["letter"].upper()
        problems.append(ProblemSummary(id=pid.lower(), name=b["name"]))
    return problems


class CodeforcesScraper(BaseScraper):
    @property
    def platform_name(self) -> str:
        return "codeforces"

    async def scrape_contest_metadata(self, contest_id: str) -> MetadataResult:
        try:
            problems = await asyncio.to_thread(
                _scrape_contest_problems_sync, contest_id
            )
            if not problems:
                return self._metadata_error(
                    f"No problems found for contest {contest_id}"
                )
            return MetadataResult(
                success=True,
                error="",
                contest_id=contest_id,
                problems=problems,
                url=f"https://codeforces.com/contest/{contest_id}/problem/%s",
            )
        except Exception as e:
            return self._metadata_error(str(e))

    async def scrape_contest_list(self) -> ContestListResult:
        try:
            r = requests.get(API_CONTEST_LIST_URL, timeout=TIMEOUT_SECONDS)
            r.raise_for_status()
            data = r.json()
            if data.get("status") != "OK":
                return self._contests_error("Invalid API response")

            contests: list[ContestSummary] = []
            for c in data["result"]:
                if c.get("phase") != "FINISHED":
                    continue
                cid = str(c["id"])
                name = c["name"]
                contests.append(ContestSummary(id=cid, name=name, display_name=name))

            if not contests:
                return self._contests_error("No contests found")

            return ContestListResult(success=True, error="", contests=contests)
        except Exception as e:
            return self._contests_error(str(e))

    async def stream_tests_for_category_async(self, category_id: str) -> None:
        html = await asyncio.to_thread(_fetch_problems_html, category_id)
        blocks = await asyncio.to_thread(_parse_all_blocks, html)

        for b in blocks:
            pid = b["letter"].lower()
            tests: list[TestCase] = b.get("tests", [])
            print(
                json.dumps(
                    {
                        "problem_id": pid,
                        "combined": {
                            "input": b.get("combined_input", ""),
                            "expected": b.get("combined_expected", ""),
                        },
                        "tests": [
                            {"input": t.input, "expected": t.expected} for t in tests
                        ],
                        "timeout_ms": b.get("timeout_ms", 0),
                        "memory_mb": b.get("memory_mb", 0),
                        "interactive": bool(b.get("interactive")),
                        "multi_test": bool(b.get("multi_test", False)),
                    }
                ),
                flush=True,
            )


if __name__ == "__main__":
    CodeforcesScraper().run_cli()

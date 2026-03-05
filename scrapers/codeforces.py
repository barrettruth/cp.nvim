#!/usr/bin/env python3

import asyncio
import json
import re
from typing import Any

import requests
from bs4 import BeautifulSoup, Tag
from curl_cffi import requests as curl_requests

from .base import BaseScraper, extract_precision
from .models import (
    ContestListResult,
    ContestSummary,
    MetadataResult,
    ProblemSummary,
    SubmitResult,
    TestCase,
)
from .timeouts import (
    BROWSER_NAV_TIMEOUT,
    BROWSER_SESSION_TIMEOUT,
    HTTP_TIMEOUT,
)

BASE_URL = "https://codeforces.com"
API_CONTEST_LIST_URL = f"{BASE_URL}/api/contest.list"
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
    if not isinstance(st, Tag):
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
    response = curl_requests.get(url, impersonate="chrome", timeout=HTTP_TIMEOUT)
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
        precision = extract_precision(b.get_text(" ", strip=True))

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
                "precision": precision,
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
            r = requests.get(API_CONTEST_LIST_URL, timeout=HTTP_TIMEOUT)
            r.raise_for_status()
            data = r.json()
            if data.get("status") != "OK":
                return self._contests_error("Invalid API response")

            contests: list[ContestSummary] = []
            for c in data["result"]:
                phase = c.get("phase")
                if phase not in ("FINISHED", "BEFORE", "CODING"):
                    continue
                cid = str(c["id"])
                name = c["name"]
                start_time = c.get("startTimeSeconds") if phase != "FINISHED" else None
                contests.append(
                    ContestSummary(
                        id=cid,
                        name=name,
                        display_name=name,
                        start_time=start_time,
                    )
                )

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
                        "precision": b.get("precision"),
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
        return await asyncio.to_thread(
            _submit_headless,
            contest_id,
            problem_id,
            source_code,
            language_id,
            credentials,
        )


def _submit_headless(
    contest_id: str,
    problem_id: str,
    source_code: str,
    language_id: str,
    credentials: dict[str, str],
    _retried: bool = False,
) -> SubmitResult:
    from pathlib import Path

    try:
        from scrapling.fetchers import StealthySession  # type: ignore[import-untyped,unresolved-import]
    except ImportError:
        return SubmitResult(
            success=False,
            error="scrapling is required for Codeforces submit",
        )

    from .atcoder import _ensure_browser, _solve_turnstile

    _ensure_browser()

    cookie_cache = Path.home() / ".cache" / "cp-nvim" / "codeforces-cookies.json"
    cookie_cache.parent.mkdir(parents=True, exist_ok=True)
    saved_cookies: list[dict[str, Any]] = []
    if cookie_cache.exists():
        try:
            saved_cookies = json.loads(cookie_cache.read_text())
        except Exception:
            pass

    logged_in = cookie_cache.exists() and not _retried
    login_error: str | None = None
    submit_error: str | None = None
    needs_relogin = False

    def check_login(page):
        nonlocal logged_in
        logged_in = page.evaluate(
            "() => Array.from(document.querySelectorAll('a'))"
            ".some(a => a.textContent.includes('Logout'))"
        )

    def login_action(page):
        nonlocal login_error
        try:
            page.fill(
                'input[name="handleOrEmail"]',
                credentials.get("username", ""),
            )
            page.fill(
                'input[name="password"]',
                credentials.get("password", ""),
            )
            page.locator('#enterForm input[type="submit"]').click()
            page.wait_for_url(
                lambda url: "/enter" not in url, timeout=BROWSER_NAV_TIMEOUT
            )
        except Exception as e:
            login_error = str(e)

    def submit_action(page):
        nonlocal submit_error, needs_relogin
        if "/enter" in page.url or "/login" in page.url:
            needs_relogin = True
            return
        try:
            _solve_turnstile(page)
        except Exception:
            pass
        try:
            page.select_option(
                'select[name="submittedProblemIndex"]',
                problem_id.upper(),
            )
            page.select_option('select[name="programTypeId"]', language_id)
            page.fill('textarea[name="source"]', source_code)
            page.locator("form.submit-form input.submit").click(no_wait_after=True)
            try:
                page.wait_for_url(
                    lambda url: "/my" in url or "/status" in url,
                    timeout=BROWSER_NAV_TIMEOUT * 2,
                )
            except Exception:
                err_el = page.query_selector("span.error")
                if err_el:
                    submit_error = err_el.inner_text().strip()
                else:
                    submit_error = "Submit failed: page did not navigate"
        except Exception as e:
            submit_error = str(e)

    try:
        with StealthySession(
            headless=True,
            timeout=BROWSER_SESSION_TIMEOUT,
            google_search=False,
            cookies=saved_cookies if (cookie_cache.exists() and not _retried) else [],
        ) as session:
            if not (cookie_cache.exists() and not _retried):
                print(json.dumps({"status": "checking_login"}), flush=True)
                session.fetch(
                    f"{BASE_URL}/",
                    page_action=check_login,
                    network_idle=True,
                )

            if not logged_in:
                print(json.dumps({"status": "logging_in"}), flush=True)
                session.fetch(
                    f"{BASE_URL}/enter",
                    page_action=login_action,
                    solve_cloudflare=True,
                )
                if login_error:
                    return SubmitResult(
                        success=False, error=f"Login failed: {login_error}"
                    )

            print(json.dumps({"status": "submitting"}), flush=True)
            session.fetch(
                f"{BASE_URL}/contest/{contest_id}/submit",
                page_action=submit_action,
                solve_cloudflare=False,
            )

            try:
                browser_cookies = session.context.cookies()
                if any(c["name"] == "JSESSIONID" for c in browser_cookies):
                    cookie_cache.write_text(json.dumps(browser_cookies))
            except Exception:
                pass

        if needs_relogin and not _retried:
            cookie_cache.unlink(missing_ok=True)
            return _submit_headless(
                contest_id,
                problem_id,
                source_code,
                language_id,
                credentials,
                _retried=True,
            )

        if submit_error:
            return SubmitResult(success=False, error=submit_error)

        return SubmitResult(
            success=True,
            error="",
            submission_id="",
            verdict="submitted",
        )
    except Exception as e:
        return SubmitResult(success=False, error=str(e))


if __name__ == "__main__":
    CodeforcesScraper().run_cli()

#!/usr/bin/env python3

import asyncio
import json
import re
from pathlib import Path
from typing import Any, cast

import httpx

from .base import (
    BaseScraper,
    extract_precision,
    load_platform_cookies,
    save_platform_cookies,
)
from .timeouts import HTTP_TIMEOUT
from .models import (
    ContestListResult,
    ContestSummary,
    LoginResult,
    MetadataResult,
    ProblemSummary,
    SubmitResult,
    TestCase,
)

BASE_URL = "http://www.usaco.org"
_AUTH_BASE = "https://usaco.org"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
}
CONNECTIONS = 4

_LOGIN_PATH = "/current/tpcm/login-session.php"
_SUBMIT_PATH = "/current/tpcm/submit-solution.php"

_LANG_KEYWORDS: dict[str, list[str]] = {
    "cpp": ["c++17", "c++ 17", "g++17", "c++", "cpp"],
    "python": ["python3", "python 3", "python"],
    "java": ["java"],
}

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
            div = heading_m.group(3)
            if div:
                key = div.lower()
                current_div = key
                sections.setdefault(key, [])
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
    precision = extract_precision(html)

    return {
        "tests": tests,
        "timeout_ms": timeout_ms,
        "memory_mb": memory_mb,
        "interactive": interactive,
        "precision": precision,
    }


def _pick_lang_option(select_body: str, language_id: str) -> str | None:
    keywords = _LANG_KEYWORDS.get(language_id.lower(), [language_id.lower()])
    options = [
        (m.group(1), m.group(2).strip().lower())
        for m in re.finditer(
            r'<option\b[^>]*\bvalue=["\']([^"\']*)["\'][^>]*>([^<]+)',
            select_body,
            re.IGNORECASE,
        )
    ]
    for kw in keywords:
        for val, text in options:
            if kw in text:
                return val
    return None


def _parse_submit_form(
    html: str, language_id: str
) -> tuple[str, dict[str, str], str | None]:
    form_action = _AUTH_BASE + _SUBMIT_PATH
    hidden: dict[str, str] = {}
    lang_val: str | None = None
    for form_m in re.finditer(
        r'<form\b[^>]*action=["\']([^"\']+)["\'][^>]*>(.*?)</form>',
        html,
        re.DOTALL | re.IGNORECASE,
    ):
        action, body = form_m.group(1), form_m.group(2)
        if "sourcefile" not in body.lower():
            continue
        if action.startswith("http"):
            form_action = action
        elif action.startswith("/"):
            form_action = _AUTH_BASE + action
        else:
            form_action = _AUTH_BASE + "/" + action
        for input_m in re.finditer(
            r'<input\b[^>]*\btype=["\']hidden["\'][^>]*/?>',
            body,
            re.IGNORECASE,
        ):
            tag = input_m.group(0)
            name_m = re.search(r'\bname=["\']([^"\']+)["\']', tag, re.IGNORECASE)
            val_m = re.search(r'\bvalue=["\']([^"\']*)["\']', tag, re.IGNORECASE)
            if name_m and val_m:
                hidden[name_m.group(1)] = val_m.group(1)
        for sel_m in re.finditer(
            r'<select\b[^>]*\bname=["\']([^"\']+)["\'][^>]*>(.*?)</select>',
            body,
            re.DOTALL | re.IGNORECASE,
        ):
            name, sel_body = sel_m.group(1), sel_m.group(2)
            if "lang" in name.lower():
                lang_val = _pick_lang_option(sel_body, language_id)
                break
        break
    return form_action, hidden, lang_val


async def _load_usaco_cookies(client: httpx.AsyncClient) -> None:
    data = load_platform_cookies("usaco")
    if isinstance(data, dict):
        for k, v in data.items():
            client.cookies.set(k, v)


async def _save_usaco_cookies(client: httpx.AsyncClient) -> None:
    cookies = dict(client.cookies.items())
    if cookies:
        save_platform_cookies("usaco", cookies)


async def _check_usaco_login(client: httpx.AsyncClient, username: str) -> bool:
    try:
        r = await client.get(
            f"{_AUTH_BASE}/index.php",
            headers=HEADERS,
            timeout=HTTP_TIMEOUT,
        )
        text = r.text.lower()
        return username.lower() in text or "logout" in text
    except Exception:
        return False


async def _do_usaco_login(
    client: httpx.AsyncClient, username: str, password: str
) -> bool:
    r = await client.post(
        f"{_AUTH_BASE}{_LOGIN_PATH}",
        data={"uname": username, "password": password},
        headers=HEADERS,
        timeout=HTTP_TIMEOUT,
    )
    r.raise_for_status()
    try:
        return r.json().get("code") == 1
    except Exception:
        return False


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
                return ContestListResult(
                    success=False, error="No contests found", supports_countdown=False
                )
            return ContestListResult(
                success=True, error="", contests=contests, supports_countdown=False
            )
        except Exception as e:
            return ContestListResult(
                success=False, error=str(e), supports_countdown=False
            )

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
                            "precision": None,
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
                        "precision": info["precision"],
                    }

            tasks = [run_one(cpid) for cpid, _ in problems_raw]
            for coro in asyncio.as_completed(tasks):
                payload = await coro
                print(json.dumps(payload), flush=True)

    async def submit(
        self,
        contest_id: str,
        problem_id: str,
        file_path: str,
        language_id: str,
        credentials: dict[str, str],
    ) -> SubmitResult:
        source = Path(file_path).read_bytes()
        username = credentials.get("username", "")
        password = credentials.get("password", "")
        if not username or not password:
            return self._submit_error("Missing credentials. Use :CP usaco login")

        async with httpx.AsyncClient(follow_redirects=True) as client:
            await _load_usaco_cookies(client)
            if client.cookies:
                print(json.dumps({"status": "checking_login"}), flush=True)
                if not await _check_usaco_login(client, username):
                    client.cookies.clear()
                    print(json.dumps({"status": "logging_in"}), flush=True)
                    try:
                        ok = await _do_usaco_login(client, username, password)
                    except Exception as e:
                        return self._submit_error(f"Login failed: {e}")
                    if not ok:
                        return self._submit_error("Login failed (bad credentials?)")
                    await _save_usaco_cookies(client)
            else:
                print(json.dumps({"status": "logging_in"}), flush=True)
                try:
                    ok = await _do_usaco_login(client, username, password)
                except Exception as e:
                    return self._submit_error(f"Login failed: {e}")
                if not ok:
                    return self._submit_error("Login failed (bad credentials?)")
                await _save_usaco_cookies(client)

            result = await self._do_submit(client, problem_id, language_id, source)

            if result.success or result.error != "auth_failure":
                return result

            client.cookies.clear()
            print(json.dumps({"status": "logging_in"}), flush=True)
            try:
                ok = await _do_usaco_login(client, username, password)
            except Exception as e:
                return self._submit_error(f"Login failed: {e}")
            if not ok:
                return self._submit_error("Login failed (bad credentials?)")
            await _save_usaco_cookies(client)

            return await self._do_submit(client, problem_id, language_id, source)

    async def _do_submit(
        self,
        client: httpx.AsyncClient,
        problem_id: str,
        language_id: str,
        source: bytes,
    ) -> SubmitResult:
        print(json.dumps({"status": "submitting"}), flush=True)
        try:
            page_r = await client.get(
                f"{_AUTH_BASE}/index.php?page=viewproblem2&cpid={problem_id}",
                headers=HEADERS,
                timeout=HTTP_TIMEOUT,
            )
            page_url = str(page_r.url)
            if "/login" in page_url or "Login" in page_r.text[:2000]:
                return self._submit_error("auth_failure")
            form_url, hidden_fields, lang_val = _parse_submit_form(
                page_r.text, language_id
            )
        except Exception:
            form_url = _AUTH_BASE + _SUBMIT_PATH
            hidden_fields = {}
            lang_val = None

        data: dict[str, str] = {"cpid": problem_id, **hidden_fields}
        data["language"] = lang_val if lang_val is not None else language_id
        ext = "py" if "python" in language_id.lower() else "cpp"
        try:
            r = await client.post(
                form_url,
                data=data,
                files={"sourcefile": (f"solution.{ext}", source, "text/plain")},
                headers=HEADERS,
                timeout=HTTP_TIMEOUT,
            )
            r.raise_for_status()
        except Exception as e:
            return self._submit_error(f"Submit request failed: {e}")

        try:
            resp = r.json()
            if resp.get("code") == 0 and "login" in resp.get("message", "").lower():
                return self._submit_error("auth_failure")
            sid = str(resp.get("submission_id", resp.get("id", "")))
        except Exception:
            sid = ""
        return SubmitResult(
            success=True, error="", submission_id=sid, verdict="submitted"
        )

    async def login(self, credentials: dict[str, str]) -> LoginResult:
        username = credentials.get("username", "")
        password = credentials.get("password", "")
        if not username or not password:
            return self._login_error("Missing username or password")

        async with httpx.AsyncClient(follow_redirects=True) as client:
            await _load_usaco_cookies(client)
            if client.cookies:
                print(json.dumps({"status": "checking_login"}), flush=True)
                if await _check_usaco_login(client, username):
                    return LoginResult(
                        success=True,
                        error="",
                        credentials={"username": username, "password": password},
                    )

            print(json.dumps({"status": "logging_in"}), flush=True)
            try:
                ok = await _do_usaco_login(client, username, password)
            except Exception as e:
                return self._login_error(f"Login request failed: {e}")

            if not ok:
                return self._login_error("Login failed (bad credentials?)")

            await _save_usaco_cookies(client)
        return LoginResult(
            success=True,
            error="",
            credentials={"username": username, "password": password},
        )


if __name__ == "__main__":
    USACOScraper().run_cli()

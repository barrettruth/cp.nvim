#!/usr/bin/env python3

import asyncio
import json
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Any

import backoff
import httpx
import requests
from bs4 import BeautifulSoup, Tag
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from .base import BaseScraper, extract_precision
from .models import (
    ContestListResult,
    ContestSummary,
    LoginResult,
    MetadataResult,
    ProblemSummary,
    SubmitResult,
    TestCase,
)
from .timeouts import (
    BROWSER_ELEMENT_WAIT,
    BROWSER_NAV_TIMEOUT,
    BROWSER_SESSION_TIMEOUT,
    BROWSER_SETTLE_DELAY,
    BROWSER_SUBMIT_NAV_TIMEOUT,
    BROWSER_TURNSTILE_POLL,
    HTTP_TIMEOUT,
)

_LANGUAGE_ID_EXTENSION = {
    "6017": "cc",
    "6082": "py",
}

MIB_TO_MB = 1.048576
BASE_URL = "https://atcoder.jp"
ARCHIVE_URL = f"{BASE_URL}/contests/archive"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
}
RETRY_STATUS = {429, 502, 503, 504}
FATAL_STATUS = {400, 401, 403, 404, 410}

_session = requests.Session()
_adapter = HTTPAdapter(
    pool_connections=100,
    pool_maxsize=100,
    max_retries=Retry(total=0),
)
_session.mount("https://", _adapter)
_session.mount("http://", _adapter)


def _give_up_requests(exc: Exception) -> bool:
    if isinstance(exc, requests.HTTPError) and exc.response is not None:
        return exc.response.status_code in FATAL_STATUS
    return False


def _retry_after_requests(details):
    exc = details.get("exception")
    if isinstance(exc, requests.HTTPError) and exc.response is not None:
        ra = exc.response.headers.get("Retry-After")
        if ra:
            try:
                time.sleep(max(0.0, float(ra)))
            except ValueError:
                pass


@backoff.on_exception(
    backoff.expo,
    (requests.ConnectionError, requests.Timeout, requests.HTTPError),
    max_tries=5,
    jitter=backoff.full_jitter,
    giveup=_give_up_requests,
    on_backoff=_retry_after_requests,
)
def _fetch(url: str) -> str:
    r = _session.get(url, headers=HEADERS, timeout=HTTP_TIMEOUT)
    if r.status_code in RETRY_STATUS:
        raise requests.HTTPError(response=r)
    r.raise_for_status()
    return r.text


def _giveup_httpx(exc: Exception) -> bool:
    return (
        isinstance(exc, httpx.HTTPStatusError)
        and exc.response is not None
        and (exc.response.status_code in FATAL_STATUS)
    )


@backoff.on_exception(
    backoff.expo,
    (httpx.ConnectError, httpx.ReadTimeout, httpx.HTTPStatusError),
    max_tries=5,
    jitter=backoff.full_jitter,
    giveup=_giveup_httpx,
)
async def _get_async(client: httpx.AsyncClient, url: str) -> str:
    r = await client.get(url, headers=HEADERS, timeout=HTTP_TIMEOUT)
    r.raise_for_status()
    return r.text


def _text_from_pre(pre: Tag) -> str:
    return (
        pre.get_text(separator="\n", strip=False)
        .replace("\r", "")
        .replace("\xa0", " ")
        .rstrip("\n")
    )


def _parse_last_page(html: str) -> int:
    soup = BeautifulSoup(html, "html.parser")
    nav = soup.select_one("ul.pagination")
    if not nav:
        return 1
    nums = []
    for a in nav.select("a"):
        s = a.get_text(strip=True)
        if s.isdigit():
            nums.append(int(s))
    return max(nums) if nums else 1


def _parse_start_time(tr: Tag) -> int | None:
    tds = tr.select("td")
    if not tds:
        return None
    time_el = tds[0].select_one("time.fixtime-full")
    if not time_el:
        return None
    text = time_el.get_text(strip=True)
    try:
        from datetime import datetime

        dt = datetime.strptime(text, "%Y-%m-%d %H:%M:%S%z")
        return int(dt.timestamp())
    except (ValueError, TypeError):
        return None


def _parse_archive_contests(html: str) -> list[ContestSummary]:
    soup = BeautifulSoup(html, "html.parser")
    tbody = soup.select_one("table.table-default tbody") or soup.select_one("tbody")
    if not tbody:
        return []
    out: list[ContestSummary] = []
    for tr in tbody.select("tr"):
        a = tr.select_one("a[href^='/contests/']")
        if not a:
            continue
        href_attr = a.get("href")
        if not isinstance(href_attr, str):
            continue
        m = re.search(r"/contests/([^/?#]+)", href_attr)
        if not m:
            continue
        cid = m.group(1)
        name = a.get_text(strip=True)
        start_time = _parse_start_time(tr)
        out.append(
            ContestSummary(id=cid, name=name, display_name=name, start_time=start_time)
        )
    return out


def _parse_tasks_list(html: str) -> list[dict[str, str]]:
    soup = BeautifulSoup(html, "html.parser")
    tbody = soup.select_one("table tbody")
    if not tbody:
        return []
    rows: list[dict[str, str]] = []
    for tr in tbody.select("tr"):
        tds = tr.select("td")
        if len(tds) < 2:
            continue
        letter = tds[0].get_text(strip=True)
        a = tds[1].select_one("a[href*='/tasks/']")
        if not a:
            continue
        href_attr = a.get("href")
        if not isinstance(href_attr, str):
            continue
        m = re.search(r"/contests/[^/]+/tasks/([^/?#]+)", href_attr)
        if not m:
            continue
        slug = m.group(1)
        title = a.get_text(strip=True)
        rows.append({"letter": letter, "title": title, "slug": slug})
    return rows


def _extract_problem_info(html: str) -> tuple[int, float, bool, float | None]:
    soup = BeautifulSoup(html, "html.parser")
    txt = soup.get_text(" ", strip=True)
    timeout_ms = 0
    memory_mb = 0.0
    ts = re.search(r"Time\s*Limit:\s*([\d.]+)\s*sec", txt, flags=re.I)
    if ts:
        timeout_ms = int(float(ts.group(1)) * 1000)
    ms = re.search(r"Memory\s*Limit:\s*(\d+)\s*MiB", txt, flags=re.I)
    if ms:
        memory_mb = float(ms.group(1)) * MIB_TO_MB
    div = soup.select_one("#problem-statement")
    body = div.get_text(" ", strip=True) if div else soup.get_text(" ", strip=True)
    interactive = "This is an interactive" in body
    precision = extract_precision(body)
    return timeout_ms, memory_mb, interactive, precision


def _extract_samples(html: str) -> list[TestCase]:
    soup = BeautifulSoup(html, "html.parser")
    root = soup.select_one("#task-statement") or soup
    inputs: dict[str, str] = {}
    outputs: dict[str, str] = {}
    for h in root.find_all(re.compile(r"h[2-4]")):
        title = h.get_text(" ", strip=True)
        pre = h.find_next("pre")
        if not pre:
            continue
        t = _text_from_pre(pre)
        mi = re.search(r"Sample\s*Input\s*(\d+)", title, flags=re.I)
        mo = re.search(r"Sample\s*Output\s*(\d+)", title, flags=re.I)
        if mi:
            inputs[mi.group(1)] = t.strip()
        elif mo:
            outputs[mo.group(1)] = t.strip()
    cases: list[TestCase] = []
    for k in sorted(set(inputs) & set(outputs), key=lambda s: int(s)):
        cases.append(TestCase(input=inputs[k], expected=outputs[k]))
    return cases


_TURNSTILE_JS = "() => { const el = document.querySelector('[name=\"cf-turnstile-response\"]'); return el && el.value.length > 0; }"


def _solve_turnstile(page) -> None:
    if page.evaluate(_TURNSTILE_JS):
        return
    iframe_loc = page.locator('iframe[src*="challenges.cloudflare.com"]')
    if not iframe_loc.count():
        return
    for _ in range(6):
        try:
            box = iframe_loc.first.bounding_box()
            if box:
                page.mouse.click(
                    box["x"] + box["width"] * 0.15,
                    box["y"] + box["height"] * 0.5,
                )
        except Exception:
            pass
        try:
            page.wait_for_function(_TURNSTILE_JS, timeout=BROWSER_TURNSTILE_POLL)
            return
        except Exception:
            pass
    raise RuntimeError("Turnstile not solved after multiple attempts")


def _ensure_browser() -> None:
    try:
        from patchright._impl._driver import compute_driver_executable  # type: ignore[import-untyped,unresolved-import]

        node, cli = compute_driver_executable()
    except Exception:
        return
    browser_info = subprocess.run(
        [node, cli, "install", "--dry-run", "chromium"],
        capture_output=True,
        text=True,
    )
    for line in browser_info.stdout.splitlines():
        if "Install location:" in line:
            install_dir = line.split(":", 1)[1].strip()
            if not os.path.isdir(install_dir):
                print(json.dumps({"status": "installing_browser"}), flush=True)
                subprocess.run([node, cli, "install", "chromium"], check=True)
            break


def _login_headless(credentials: dict[str, str]) -> LoginResult:
    try:
        from scrapling.fetchers import StealthySession  # type: ignore[import-untyped,unresolved-import]
    except ImportError:
        return LoginResult(
            success=False,
            error="scrapling is required for AtCoder login. Install it: uv add 'scrapling[fetchers]>=0.4'",
        )

    _ensure_browser()

    cookie_cache = Path.home() / ".cache" / "cp-nvim" / "atcoder-cookies.json"
    cookie_cache.parent.mkdir(parents=True, exist_ok=True)
    saved_cookies: list[dict[str, Any]] = []
    if cookie_cache.exists():
        try:
            saved_cookies = json.loads(cookie_cache.read_text())
        except Exception:
            pass

    logged_in = False
    login_error: str | None = None

    def check_login(page):
        nonlocal logged_in
        logged_in = page.evaluate(
            "() => Array.from(document.querySelectorAll('a')).some(a => a.textContent.trim() === 'Sign Out')"
        )

    def login_action(page):
        nonlocal login_error
        try:
            _solve_turnstile(page)
            page.fill('input[name="username"]', credentials.get("username", ""))
            page.fill('input[name="password"]', credentials.get("password", ""))
            page.click("#submit")
            page.wait_for_url(
                lambda url: "/login" not in url, timeout=BROWSER_NAV_TIMEOUT
            )
        except Exception as e:
            login_error = str(e)

    try:
        with StealthySession(
            headless=True,
            timeout=BROWSER_SESSION_TIMEOUT,
            google_search=False,
            cookies=saved_cookies if saved_cookies else [],
        ) as session:
            if saved_cookies:
                print(json.dumps({"status": "checking_login"}), flush=True)
                session.fetch(
                    f"{BASE_URL}/home", page_action=check_login, network_idle=True
                )

            if not logged_in:
                print(json.dumps({"status": "logging_in"}), flush=True)
                session.fetch(
                    f"{BASE_URL}/login",
                    page_action=login_action,
                    solve_cloudflare=True,
                )
                if login_error:
                    return LoginResult(
                        success=False, error=f"Login failed: {login_error}"
                    )

                session.fetch(
                    f"{BASE_URL}/home", page_action=check_login, network_idle=True
                )
                if not logged_in:
                    return LoginResult(
                        success=False, error="Login failed (bad credentials?)"
                    )

            try:
                browser_cookies = session.context.cookies()
                if any(c["name"] == "REVEL_SESSION" for c in browser_cookies):
                    cookie_cache.write_text(json.dumps(browser_cookies))
            except Exception:
                pass

        return LoginResult(success=True, error="")
    except Exception as e:
        return LoginResult(success=False, error=str(e))


def _submit_headless(
    contest_id: str,
    problem_id: str,
    file_path: str,
    language_id: str,
    credentials: dict[str, str],
    _retried: bool = False,
) -> "SubmitResult":
    try:
        from scrapling.fetchers import StealthySession  # type: ignore[import-untyped,unresolved-import]
    except ImportError:
        return SubmitResult(
            success=False,
            error="scrapling is required for AtCoder submit. Install it: uv add 'scrapling[fetchers]>=0.4'",
        )

    _ensure_browser()

    cookie_cache = Path.home() / ".cache" / "cp-nvim" / "atcoder-cookies.json"
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
            "() => Array.from(document.querySelectorAll('a')).some(a => a.textContent.trim() === 'Sign Out')"
        )

    def login_action(page):
        nonlocal login_error
        try:
            _solve_turnstile(page)
            page.fill('input[name="username"]', credentials.get("username", ""))
            page.fill('input[name="password"]', credentials.get("password", ""))
            page.click("#submit")
            page.wait_for_url(
                lambda url: "/login" not in url, timeout=BROWSER_NAV_TIMEOUT
            )
        except Exception as e:
            login_error = str(e)

    def submit_action(page):
        nonlocal submit_error, needs_relogin
        if "/login" in page.url:
            needs_relogin = True
            return
        try:
            _solve_turnstile(page)
            page.select_option(
                'select[name="data.TaskScreenName"]',
                f"{contest_id}_{problem_id}",
            )
            page.locator(
                f'select[name="data.LanguageId"] option[value="{language_id}"]'
            ).wait_for(state="attached", timeout=BROWSER_ELEMENT_WAIT)
            page.select_option('select[name="data.LanguageId"]', language_id)
            page.set_input_files("#input-open-file", file_path)
            page.wait_for_timeout(BROWSER_SETTLE_DELAY)
            page.locator('button[type="submit"]').click()
            page.wait_for_url(
                lambda url: "/submissions/me" in url,
                timeout=BROWSER_SUBMIT_NAV_TIMEOUT["atcoder"],
            )
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
                    f"{BASE_URL}/home", page_action=check_login, network_idle=True
                )

            if not logged_in:
                print(json.dumps({"status": "logging_in"}), flush=True)
                session.fetch(
                    f"{BASE_URL}/login",
                    page_action=login_action,
                    solve_cloudflare=True,
                )
                if login_error:
                    return SubmitResult(
                        success=False, error=f"Login failed: {login_error}"
                    )

            print(json.dumps({"status": "submitting"}), flush=True)
            session.fetch(
                f"{BASE_URL}/contests/{contest_id}/submit",
                page_action=submit_action,
                solve_cloudflare=True,
            )

            try:
                browser_cookies = session.context.cookies()
                if any(c["name"] == "REVEL_SESSION" for c in browser_cookies):
                    cookie_cache.write_text(json.dumps(browser_cookies))
            except Exception:
                pass

        if needs_relogin and not _retried:
            cookie_cache.unlink(missing_ok=True)
            return _submit_headless(
                contest_id,
                problem_id,
                file_path,
                language_id,
                credentials,
                _retried=True,
            )

        if submit_error:
            return SubmitResult(success=False, error=submit_error)

        return SubmitResult(
            success=True, error="", submission_id="", verdict="submitted"
        )
    except Exception as e:
        return SubmitResult(success=False, error=str(e))


def _scrape_tasks_sync(contest_id: str) -> list[dict[str, str]]:
    html = _fetch(f"{BASE_URL}/contests/{contest_id}/tasks")
    return _parse_tasks_list(html)


def _scrape_problem_page_sync(contest_id: str, slug: str) -> dict[str, Any]:
    html = _fetch(f"{BASE_URL}/contests/{contest_id}/tasks/{slug}")
    try:
        tests = _extract_samples(html)
    except Exception:
        tests = []
    timeout_ms, memory_mb, interactive, precision = _extract_problem_info(html)
    return {
        "tests": tests,
        "timeout_ms": timeout_ms,
        "memory_mb": memory_mb,
        "interactive": interactive,
        "precision": precision,
    }


def _to_problem_summaries(rows: list[dict[str, str]]) -> list[ProblemSummary]:
    out: list[ProblemSummary] = []
    for r in rows:
        letter = (r.get("letter") or "").strip().upper()
        title = r.get("title") or ""
        if not letter:
            continue
        pid = letter.lower()
        out.append(ProblemSummary(id=pid, name=title))
    return out


async def _fetch_upcoming_contests_async(
    client: httpx.AsyncClient,
) -> list[ContestSummary]:
    try:
        html = await _get_async(client, f"{BASE_URL}/contests/")
        return _parse_archive_contests(html)
    except Exception:
        return []


async def _fetch_all_contests_async() -> list[ContestSummary]:
    async with httpx.AsyncClient(
        limits=httpx.Limits(max_connections=100, max_keepalive_connections=100),
    ) as client:
        upcoming = await _fetch_upcoming_contests_async(client)
        first_html = await _get_async(client, ARCHIVE_URL)
        last = _parse_last_page(first_html)
        out = _parse_archive_contests(first_html)
        if last <= 1:
            seen = {c.id for c in out}
            for c in upcoming:
                if c.id not in seen:
                    out.append(c)
            return out
        tasks = [
            asyncio.create_task(_get_async(client, f"{ARCHIVE_URL}?page={p}"))
            for p in range(2, last + 1)
        ]
        for coro in asyncio.as_completed(tasks):
            html = await coro
            out.extend(_parse_archive_contests(html))
        seen = {c.id for c in out}
        for c in upcoming:
            if c.id not in seen:
                out.append(c)
        return out


class AtcoderScraper(BaseScraper):
    @property
    def platform_name(self) -> str:
        return "atcoder"

    async def scrape_contest_metadata(self, contest_id: str) -> MetadataResult:
        try:
            rows = await asyncio.to_thread(_scrape_tasks_sync, contest_id)
            problems = _to_problem_summaries(rows)
            if not problems:
                return self._metadata_error(
                    f"No problems found for contest {contest_id}"
                )
            return MetadataResult(
                success=True,
                error="",
                contest_id=contest_id,
                problems=problems,
                url=f"https://atcoder.jp/contests/{contest_id}/tasks/{contest_id}_%s",
                contest_url=f"https://atcoder.jp/contests/{contest_id}",
                standings_url=f"https://atcoder.jp/contests/{contest_id}/standings",
            )
        except Exception as e:
            return self._metadata_error(str(e))

    async def scrape_contest_list(self) -> ContestListResult:
        try:
            contests = await _fetch_all_contests_async()
            if not contests:
                return self._contests_error("No contests found")
            return ContestListResult(success=True, error="", contests=contests)
        except Exception as e:
            return self._contests_error(str(e))

    async def stream_tests_for_category_async(self, category_id: str) -> None:
        rows = await asyncio.to_thread(_scrape_tasks_sync, category_id)

        async def emit(row: dict[str, str]) -> None:
            letter = (row.get("letter") or "").strip().lower()
            slug = row.get("slug") or ""
            if not letter or not slug:
                return
            data = await asyncio.to_thread(_scrape_problem_page_sync, category_id, slug)
            tests: list[TestCase] = data.get("tests", [])
            combined_input = "\n".join(t.input for t in tests) if tests else ""
            combined_expected = "\n".join(t.expected for t in tests) if tests else ""
            print(
                json.dumps(
                    {
                        "problem_id": letter,
                        "combined": {
                            "input": combined_input,
                            "expected": combined_expected,
                        },
                        "tests": [
                            {"input": t.input, "expected": t.expected} for t in tests
                        ],
                        "timeout_ms": data.get("timeout_ms", 0),
                        "memory_mb": data.get("memory_mb", 0),
                        "interactive": bool(data.get("interactive")),
                        "multi_test": False,
                        "precision": data.get("precision"),
                    }
                ),
                flush=True,
            )

        await asyncio.gather(*(emit(r) for r in rows))

    async def submit(
        self,
        contest_id: str,
        problem_id: str,
        file_path: str,
        language_id: str,
        credentials: dict[str, str],
    ) -> SubmitResult:
        return await asyncio.to_thread(
            _submit_headless,
            contest_id,
            problem_id,
            file_path,
            language_id,
            credentials,
        )

    async def login(self, credentials: dict[str, str]) -> LoginResult:
        if not credentials.get("username") or not credentials.get("password"):
            return self._login_error("Missing username or password")
        return await asyncio.to_thread(_login_headless, credentials)


if __name__ == "__main__":
    AtcoderScraper().run_cli()

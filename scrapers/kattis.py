#!/usr/bin/env python3

import asyncio
import io
import json
import re
import zipfile
from datetime import datetime
from pathlib import Path

import httpx

from .base import BaseScraper
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

BASE_URL = "https://open.kattis.com"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
}
CONNECTIONS = 8

_COOKIE_PATH = Path.home() / ".cache" / "cp-nvim" / "kattis-cookies.json"

TIME_RE = re.compile(
    r"CPU Time limit</span>\s*<span[^>]*>\s*(\d+)\s*seconds?\s*</span>",
    re.DOTALL,
)
MEM_RE = re.compile(
    r"Memory limit</span>\s*<span[^>]*>\s*(\d+)\s*MB\s*</span>",
    re.DOTALL,
)


async def _fetch_text(client: httpx.AsyncClient, url: str) -> str:
    r = await client.get(url, headers=HEADERS, timeout=HTTP_TIMEOUT)
    r.raise_for_status()
    return r.text


async def _fetch_bytes(client: httpx.AsyncClient, url: str) -> bytes:
    r = await client.get(url, headers=HEADERS, timeout=HTTP_TIMEOUT)
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


def _parse_contests_page(html: str) -> list[ContestSummary]:
    results: list[ContestSummary] = []
    seen: set[str] = set()
    for row_m in re.finditer(r"<tr[^>]*>(.*?)</tr>", html, re.DOTALL):
        row = row_m.group(1)
        link_m = re.search(r'href="/contests/([a-z0-9]+)"[^>]*>([^<]+)</a>', row)
        if not link_m:
            continue
        cid = link_m.group(1)
        name = link_m.group(2).strip()
        if cid in seen:
            continue
        seen.add(cid)
        start_time: int | None = None
        ts_m = re.search(r'data-timestamp="(\d+)"', row)
        if ts_m:
            start_time = int(ts_m.group(1))
        else:
            time_m = re.search(r'<time[^>]+datetime="([^"]+)"', row)
            if time_m:
                try:
                    dt = datetime.fromisoformat(time_m.group(1).replace("Z", "+00:00"))
                    start_time = int(dt.timestamp())
                except Exception:
                    pass
        results.append(
            ContestSummary(id=cid, name=name, display_name=name, start_time=start_time)
        )
    return results


def _parse_contest_problem_list(html: str) -> list[tuple[str, str]]:
    if "The problems will become available when the contest starts" in html:
        return []
    results: list[tuple[str, str]] = []
    seen: set[str] = set()
    for row_m in re.finditer(r"<tr[^>]*>(.*?)</tr>", html, re.DOTALL):
        row = row_m.group(1)
        link_m = re.search(
            r'href="/contests/[^/]+/problems/([^"]+)"[^>]*>([^<]+)</a>', row
        )
        if not link_m:
            continue
        slug = link_m.group(1)
        name = link_m.group(2).strip()
        if slug in seen:
            continue
        seen.add(slug)
        label_m = re.search(r"<td[^>]*>\s*([A-Z])\s*</td>", row)
        label = label_m.group(1) if label_m else ""
        display = f"{label} - {name}" if label else name
        results.append((slug, display))
    return results


async def _fetch_contest_slugs(
    client: httpx.AsyncClient, contest_id: str
) -> list[tuple[str, str]]:
    try:
        html = await _fetch_text(client, f"{BASE_URL}/contests/{contest_id}/problems")
        return _parse_contest_problem_list(html)
    except httpx.HTTPStatusError:
        return []
    except Exception:
        return []


async def _stream_single_problem(client: httpx.AsyncClient, slug: str) -> None:
    try:
        html = await _fetch_text(client, f"{BASE_URL}/problems/{slug}")
    except Exception:
        return

    timeout_ms, memory_mb = _parse_limits(html)
    interactive = _is_interactive(html)

    tests: list[TestCase] = []
    try:
        zip_data = await _fetch_bytes(
            client,
            f"{BASE_URL}/problems/{slug}/file/statement/samples.zip",
        )
        tests = _parse_samples_zip(zip_data)
    except Exception:
        tests = _parse_samples_html(html)

    combined_input = "\n".join(t.input for t in tests) if tests else ""
    combined_expected = "\n".join(t.expected for t in tests) if tests else ""

    print(
        json.dumps(
            {
                "problem_id": slug,
                "combined": {
                    "input": combined_input,
                    "expected": combined_expected,
                },
                "tests": [{"input": t.input, "expected": t.expected} for t in tests],
                "timeout_ms": timeout_ms,
                "memory_mb": memory_mb,
                "interactive": interactive,
                "multi_test": False,
            }
        ),
        flush=True,
    )


async def _load_kattis_cookies(client: httpx.AsyncClient) -> None:
    if not _COOKIE_PATH.exists():
        return
    try:
        for k, v in json.loads(_COOKIE_PATH.read_text()).items():
            client.cookies.set(k, v)
    except Exception:
        pass


async def _save_kattis_cookies(client: httpx.AsyncClient) -> None:
    cookies = {k: v for k, v in client.cookies.items()}
    if cookies:
        _COOKIE_PATH.parent.mkdir(parents=True, exist_ok=True)
        _COOKIE_PATH.write_text(json.dumps(cookies))


async def _do_kattis_login(
    client: httpx.AsyncClient, username: str, password: str
) -> bool:
    client.cookies.clear()
    r = await client.post(
        f"{BASE_URL}/login",
        data={"user": username, "password": password, "script": "true"},
        headers=HEADERS,
        timeout=HTTP_TIMEOUT,
    )
    return r.status_code == 200


class KattisScraper(BaseScraper):
    @property
    def platform_name(self) -> str:
        return "kattis"

    async def scrape_contest_metadata(self, contest_id: str) -> MetadataResult:
        try:
            async with httpx.AsyncClient() as client:
                slugs = await _fetch_contest_slugs(client, contest_id)
                if slugs:
                    return MetadataResult(
                        success=True,
                        error="",
                        contest_id=contest_id,
                        problems=[
                            ProblemSummary(id=slug, name=name) for slug, name in slugs
                        ],
                        url=f"{BASE_URL}/problems/%s",
                    )
                try:
                    html = await _fetch_text(
                        client, f"{BASE_URL}/problems/{contest_id}"
                    )
                except Exception as e:
                    return self._metadata_error(str(e))
                title_m = re.search(r"<title>([^<]+)</title>", html)
                name = (
                    title_m.group(1).split("\u2013")[0].strip()
                    if title_m
                    else contest_id
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
            async with httpx.AsyncClient() as client:
                html = await _fetch_text(
                    client,
                    f"{BASE_URL}/contests?kattis_original=on&kattis_recycled=off&user_created=off",
                )
            contests = _parse_contests_page(html)
            if not contests:
                return self._contests_error("No contests found")
            return ContestListResult(success=True, error="", contests=contests)
        except Exception as e:
            return self._contests_error(str(e))

    async def stream_tests_for_category_async(self, category_id: str) -> None:
        async with httpx.AsyncClient(
            limits=httpx.Limits(max_connections=CONNECTIONS)
        ) as client:
            slugs = await _fetch_contest_slugs(client, category_id)
            if slugs:
                sem = asyncio.Semaphore(CONNECTIONS)

                async def emit_one(slug: str, _name: str) -> None:
                    async with sem:
                        await _stream_single_problem(client, slug)

                await asyncio.gather(*(emit_one(s, n) for s, n in slugs))
                return

            await _stream_single_problem(client, category_id)

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
            return self._submit_error("Missing credentials. Use :CP kattis login")

        async with httpx.AsyncClient(follow_redirects=True) as client:
            await _load_kattis_cookies(client)
            if not client.cookies:
                print(json.dumps({"status": "logging_in"}), flush=True)
                ok = await _do_kattis_login(client, username, password)
                if not ok:
                    return self._submit_error("Login failed (bad credentials?)")
                await _save_kattis_cookies(client)

            print(json.dumps({"status": "submitting"}), flush=True)
            ext = "py" if "python" in language_id.lower() else "cpp"
            data: dict[str, str] = {
                "submit": "true",
                "script": "true",
                "language": language_id,
                "problem": problem_id,
                "mainclass": "",
                "submit_ctr": "2",
            }
            if contest_id != problem_id:
                data["contest"] = contest_id

            async def _do_submit() -> httpx.Response:
                return await client.post(
                    f"{BASE_URL}/submit",
                    data=data,
                    files={"sub_file[]": (f"solution.{ext}", source, "text/plain")},
                    headers=HEADERS,
                    timeout=HTTP_TIMEOUT,
                )

            try:
                r = await _do_submit()
                r.raise_for_status()
            except Exception as e:
                return self._submit_error(f"Submit request failed: {e}")

            if r.text == "Request validation failed":
                _COOKIE_PATH.unlink(missing_ok=True)
                print(json.dumps({"status": "logging_in"}), flush=True)
                ok = await _do_kattis_login(client, username, password)
                if not ok:
                    return self._submit_error("Login failed (bad credentials?)")
                await _save_kattis_cookies(client)
                try:
                    r = await _do_submit()
                    r.raise_for_status()
                except Exception as e:
                    return self._submit_error(f"Submit request failed: {e}")

            sid_m = re.search(r"Submission ID:\s*(\d+)", r.text, re.IGNORECASE)
            sid = sid_m.group(1) if sid_m else ""
            return SubmitResult(
                success=True, error="", submission_id=sid, verdict="submitted"
            )

    async def login(self, credentials: dict[str, str]) -> LoginResult:
        username = credentials.get("username", "")
        password = credentials.get("password", "")
        if not username or not password:
            return self._login_error("Missing username or password")

        async with httpx.AsyncClient(follow_redirects=True) as client:
            print(json.dumps({"status": "logging_in"}), flush=True)
            ok = await _do_kattis_login(client, username, password)
            if not ok:
                return self._login_error("Login failed (bad credentials?)")
            await _save_kattis_cookies(client)
        return LoginResult(
            success=True,
            error="",
            credentials={"username": username, "password": password},
        )


if __name__ == "__main__":
    KattisScraper().run_cli()

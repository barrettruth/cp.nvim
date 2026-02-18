import asyncio
import importlib.util
import io
import json
import sys
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import httpx
import pytest
import requests
from curl_cffi import requests as curl_requests

ROOT = Path(__file__).resolve().parent.parent
FIX = Path(__file__).resolve().parent / "fixtures"


@pytest.fixture
def fixture_text():
    def _load(name: str) -> str:
        p = FIX / name
        return p.read_text(encoding="utf-8")

    return _load


def _load_scraper_module(module_path: Path, module_name: str):
    spec = importlib.util.spec_from_file_location(
        f"scrapers.{module_name}", module_path
    )
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot load module {module_name}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[f"scrapers.{module_name}"] = module
    spec.loader.exec_module(module)
    return module


def _capture_stdout(coro):
    buf = io.StringIO()
    old = sys.stdout
    sys.stdout = buf
    try:
        rc = asyncio.run(coro)
        out = buf.getvalue()
    finally:
        sys.stdout = old
    return rc, out


@pytest.fixture
def run_scraper_offline(fixture_text):
    def _router_cses(*, path: str | None = None, url: str | None = None) -> str:
        if not path and not url:
            raise AssertionError("CSES expects path or url")

        target = path or url
        if target is None:
            raise AssertionError(f"No target for CSES (path={path!r}, url={url!r})")

        if target.startswith("https://cses.fi"):
            target = target.removeprefix("https://cses.fi")

        if target.strip("/") == "problemset":
            return fixture_text("cses/contests.html")

        if target.startswith("/problemset/task/") or target.startswith(
            "problemset/task/"
        ):
            pid = target.rstrip("/").split("/")[-1]
            return fixture_text(f"cses/task_{pid}.html")

        raise AssertionError(f"No fixture for CSES path={path!r} url={url!r}")

    def _router_atcoder(*, path: str | None = None, url: str | None = None) -> str:
        if not url:
            raise AssertionError("AtCoder expects url routing")
        if "/contests/archive" in url:
            return fixture_text("atcoder/contests.html")
        if url.endswith("/tasks"):
            return fixture_text("atcoder/abc100_tasks.html")
        if "/tasks/" in url:
            slug = url.rsplit("/", 1)[-1]
            return fixture_text(f"atcoder/task_{slug}.html")
        raise AssertionError(f"No fixture for AtCoder url={url!r}")

    def _router_codeforces(*, path: str | None = None, url: str | None = None) -> str:
        if not url:
            raise AssertionError("Codeforces expects url routing")
        if "/contest/" in url and url.endswith("/problems"):
            contest_id = url.rstrip("/").split("/")[-2]
            return fixture_text(f"codeforces/{contest_id}_problems.html")
        if "/contests" in url and "/problem/" not in url:
            return fixture_text("codeforces/contests.html")
        if "/problem/" in url:
            parts = url.rstrip("/").split("/")
            contest_id, index = parts[-3], parts[-1]
            return fixture_text(f"codeforces/{contest_id}_{index}.html")
        if "/problemset/problem/" in url:
            parts = url.rstrip("/").split("/")
            contest_id, index = parts[-2], parts[-1]
            return fixture_text(f"codeforces/{contest_id}_{index}.html")

        raise AssertionError(f"No fixture for Codeforces url={url!r}")

    def _make_offline_fetches(scraper_name: str):
        match scraper_name:
            case "cses":

                async def __offline_fetch_text(client, path: str, **kwargs):
                    html = _router_cses(path=path)
                    return SimpleNamespace(
                        text=html,
                        status_code=200,
                        raise_for_status=lambda: None,
                    )

                return {
                    "__offline_fetch_text": __offline_fetch_text,
                }

            case "atcoder":

                def __offline_fetch(url: str, *args, **kwargs):
                    html = _router_atcoder(url=url)
                    return html

                async def __offline_get_async(client, url: str, **kwargs):
                    return _router_atcoder(url=url)

                return {
                    "_fetch": __offline_fetch,
                    "_get_async": __offline_get_async,
                }

            case "codeforces":

                class MockCurlResponse:
                    def __init__(self, html: str):
                        self.text = html

                    def raise_for_status(self):
                        pass

                def _mock_curl_get(url: str, **kwargs):
                    return MockCurlResponse(_router_codeforces(url=url))

                def _mock_requests_get(url: str, **kwargs):
                    if "api/contest.list" in url:
                        data = {
                            "status": "OK",
                            "result": [
                                {
                                    "id": 1550,
                                    "name": "Educational Codeforces Round 155 (Rated for Div. 2)",
                                    "phase": "FINISHED",
                                },
                                {
                                    "id": 1000,
                                    "name": "Codeforces Round #1000",
                                    "phase": "FINISHED",
                                },
                            ],
                        }

                        class R:
                            def json(self_inner):
                                return data

                            def raise_for_status(self_inner):
                                return None

                        return R()
                    raise AssertionError(f"Unexpected requests.get call: {url}")

                return {
                    "curl_requests.get": _mock_curl_get,
                    "requests.get": _mock_requests_get,
                }

            case "codechef":

                class MockResponse:
                    def __init__(self, json_data):
                        self._json_data = json_data
                        self.status_code = 200

                    def json(self):
                        return self._json_data

                    def raise_for_status(self):
                        pass

                async def __offline_get_async(client, url: str, **kwargs):
                    if "/api/list/contests/all" in url:
                        data = json.loads(fixture_text("codechef/contests.json"))
                        return MockResponse(data)
                    if "/api/contests/START" in url and "/problems/" not in url:
                        contest_id = url.rstrip("/").split("/")[-1]
                        try:
                            data = json.loads(
                                fixture_text(f"codechef/{contest_id}.json")
                            )
                            return MockResponse(data)
                        except FileNotFoundError:
                            raise AssertionError(f"No fixture for CodeChef url={url!r}")
                    if "/api/contests/START" in url and "/problems/" in url:
                        parts = url.rstrip("/").split("/")
                        contest_id = parts[-3]
                        problem_id = parts[-1]
                        data = json.loads(
                            fixture_text(f"codechef/{contest_id}_{problem_id}.json")
                        )
                        return MockResponse(data)
                    raise AssertionError(f"No fixture for CodeChef url={url!r}")

                class MockCodeChefCurlResponse:
                    def __init__(self, html: str):
                        self.text = html

                    def raise_for_status(self):
                        pass

                def _mock_curl_get(url: str, **kwargs):
                    if "/problems/" in url:
                        problem_id = url.rstrip("/").split("/")[-1]
                        html = fixture_text(f"codechef/{problem_id}.html")
                        return MockCodeChefCurlResponse(html)
                    raise AssertionError(f"No fixture for CodeChef url={url!r}")

                return {
                    "__offline_get_async": __offline_get_async,
                    "curl_requests.get": _mock_curl_get,
                }

            case _:
                raise AssertionError(f"Unknown scraper: {scraper_name}")

    scraper_classes = {
        "cses": "CSESScraper",
        "atcoder": "AtcoderScraper",
        "codeforces": "CodeforcesScraper",
        "codechef": "CodeChefScraper",
    }

    def _run(scraper_name: str, mode: str, *args: str):
        mod_path = ROOT / "scrapers" / f"{scraper_name}.py"
        ns = _load_scraper_module(mod_path, scraper_name)
        offline_fetches = _make_offline_fetches(scraper_name)

        if scraper_name == "codeforces":
            curl_requests.get = offline_fetches["curl_requests.get"]
            requests.get = offline_fetches["requests.get"]
        elif scraper_name == "atcoder":
            ns._fetch = offline_fetches["_fetch"]
            ns._get_async = offline_fetches["_get_async"]
        elif scraper_name == "cses":
            httpx.AsyncClient.get = offline_fetches["__offline_fetch_text"]
        elif scraper_name == "codechef":
            httpx.AsyncClient.get = offline_fetches["__offline_get_async"]
            curl_requests.get = offline_fetches["curl_requests.get"]

        scraper_class = getattr(ns, scraper_classes[scraper_name])
        scraper = scraper_class()

        argv = [str(mod_path), mode, *args]
        rc, out = _capture_stdout(scraper._run_cli_async(argv))

        json_lines: list[Any] = []
        for line in (_line for _line in out.splitlines() if _line.strip()):
            json_lines.append(json.loads(line))
        return rc, json_lines

    return _run

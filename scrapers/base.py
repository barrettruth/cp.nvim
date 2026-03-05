import asyncio
import json
import os
import re
import sys
from abc import ABC, abstractmethod

from .language_ids import get_language_id
from .models import (
    CombinedTest,
    ContestListResult,
    LoginResult,
    MetadataResult,
    SubmitResult,
    TestsResult,
)

_PRECISION_ABS_REL_RE = re.compile(
    r"(?:absolute|relative)\s+error[^.]*?10\s*[\^{]\s*\{?\s*[-\u2212]\s*(\d+)\s*\}?",
    re.IGNORECASE,
)
_PRECISION_DECIMAL_RE = re.compile(
    r"round(?:ed)?\s+to\s+(\d+)\s+decimal\s+place",
    re.IGNORECASE,
)


def extract_precision(text: str) -> float | None:
    m = _PRECISION_ABS_REL_RE.search(text)
    if m:
        return 10 ** -int(m.group(1))
    m = _PRECISION_DECIMAL_RE.search(text)
    if m:
        return 10 ** -int(m.group(1))
    return None


class BaseScraper(ABC):
    @property
    @abstractmethod
    def platform_name(self) -> str: ...

    @abstractmethod
    async def scrape_contest_metadata(self, contest_id: str) -> MetadataResult: ...

    @abstractmethod
    async def scrape_contest_list(self) -> ContestListResult: ...

    @abstractmethod
    async def stream_tests_for_category_async(self, category_id: str) -> None: ...

    @abstractmethod
    async def submit(
        self,
        contest_id: str,
        problem_id: str,
        file_path: str,
        language_id: str,
        credentials: dict[str, str],
    ) -> SubmitResult: ...

    @abstractmethod
    async def login(self, credentials: dict[str, str]) -> LoginResult: ...

    def _usage(self) -> str:
        name = self.platform_name
        return f"Usage: {name}.py metadata <id> | tests <id> | contests | login"

    def _metadata_error(self, msg: str) -> MetadataResult:
        return MetadataResult(success=False, error=msg, url="")

    def _tests_error(self, msg: str) -> TestsResult:
        return TestsResult(
            success=False,
            error=msg,
            problem_id="",
            combined=CombinedTest(input="", expected=""),
            tests=[],
            timeout_ms=0,
            memory_mb=0,
        )

    def _contests_error(self, msg: str) -> ContestListResult:
        return ContestListResult(success=False, error=msg)

    def _submit_error(self, msg: str) -> SubmitResult:
        return SubmitResult(success=False, error=msg)

    def _login_error(self, msg: str) -> LoginResult:
        return LoginResult(success=False, error=msg)

    async def _run_cli_async(self, args: list[str]) -> int:
        if len(args) < 2:
            print(self._metadata_error(self._usage()).model_dump_json())
            return 1

        mode = args[1]

        match mode:
            case "metadata":
                if len(args) != 3:
                    print(self._metadata_error(self._usage()).model_dump_json())
                    return 1
                result = await self.scrape_contest_metadata(args[2])
                print(result.model_dump_json())
                return 0 if result.success else 1

            case "tests":
                if len(args) != 3:
                    print(self._tests_error(self._usage()).model_dump_json())
                    return 1
                await self.stream_tests_for_category_async(args[2])
                return 0

            case "contests":
                if len(args) != 2:
                    print(self._contests_error(self._usage()).model_dump_json())
                    return 1
                result = await self.scrape_contest_list()
                print(result.model_dump_json())
                return 0 if result.success else 1

            case "submit":
                if len(args) != 6:
                    print(
                        self._submit_error(
                            "Usage: <platform> submit <contest_id> <problem_id> <language_id> <file_path>"
                        ).model_dump_json()
                    )
                    return 1
                creds_raw = os.environ.get("CP_CREDENTIALS", "{}")
                try:
                    credentials = json.loads(creds_raw)
                except json.JSONDecodeError:
                    credentials = {}
                language_id = get_language_id(self.platform_name, args[4]) or args[4]
                result = await self.submit(
                    args[2], args[3], args[5], language_id, credentials
                )
                print(result.model_dump_json())
                return 0 if result.success else 1

            case "login":
                creds_raw = os.environ.get("CP_CREDENTIALS", "{}")
                try:
                    credentials = json.loads(creds_raw)
                except json.JSONDecodeError:
                    credentials = {}
                result = await self.login(credentials)
                print(result.model_dump_json())
                return 0 if result.success else 1

            case _:
                print(
                    self._metadata_error(
                        f"Unknown mode: {mode}. {self._usage()}"
                    ).model_dump_json()
                )
                return 1

    def run_cli(self) -> None:
        sys.exit(asyncio.run(self._run_cli_async(sys.argv)))

from pydantic import BaseModel, ConfigDict, Field


class TestCase(BaseModel):
    input: str
    expected: str

    model_config = ConfigDict(extra="forbid")


class CombinedTest(BaseModel):
    input: str
    expected: str

    model_config = ConfigDict(extra="forbid")


class ProblemSummary(BaseModel):
    id: str
    name: str

    model_config = ConfigDict(extra="forbid")


class ContestSummary(BaseModel):
    id: str
    name: str
    display_name: str | None = None
    start_time: int | None = None

    model_config = ConfigDict(extra="forbid")


class ScrapingResult(BaseModel):
    success: bool
    error: str

    model_config = ConfigDict(extra="forbid")


class MetadataResult(ScrapingResult):
    contest_id: str = ""
    problems: list[ProblemSummary] = Field(default_factory=list)
    url: str
    contest_url: str = ""
    standings_url: str = ""

    model_config = ConfigDict(extra="forbid")


class ContestListResult(ScrapingResult):
    contests: list[ContestSummary] = Field(default_factory=list)

    model_config = ConfigDict(extra="forbid")


class TestsResult(ScrapingResult):
    problem_id: str
    combined: CombinedTest
    tests: list[TestCase] = Field(default_factory=list)
    timeout_ms: int
    memory_mb: float
    interactive: bool = False
    multi_test: bool = False

    model_config = ConfigDict(extra="forbid")


class LoginResult(ScrapingResult):
    credentials: dict[str, str] = Field(default_factory=dict)

    model_config = ConfigDict(extra="forbid")


class SubmitResult(ScrapingResult):
    submission_id: str = ""
    verdict: str = ""

    model_config = ConfigDict(extra="forbid")


class ScraperConfig(BaseModel):
    timeout_seconds: int = 30
    max_retries: int = 3
    backoff_base: float = 2.0
    rate_limit_delay: float = 1.0

    model_config = ConfigDict(extra="forbid")

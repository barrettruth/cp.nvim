import pytest

from scrapers.language_ids import LANGUAGE_IDS, get_language_id
from scrapers.models import (
    ContestListResult,
    MetadataResult,
    TestsResult,
)

MATRIX = {
    "cses": {
        "metadata": ("introductory_problems",),
        "tests": ("introductory_problems",),
        "contests": tuple(),
    },
    "atcoder": {
        "metadata": ("abc100",),
        "tests": ("abc100",),
        "contests": tuple(),
    },
    "codeforces": {
        "metadata": ("1550",),
        "tests": ("1550",),
        "contests": tuple(),
    },
    "codechef": {
        "metadata": ("START209D",),
        "tests": ("START209D",),
        "contests": tuple(),
    },
    "kattis": {
        "metadata": ("hello",),
        "tests": ("hello",),
        "contests": tuple(),
    },
    "usaco": {
        "metadata": ("dec24_gold",),
        "tests": ("dec24_gold",),
        "contests": tuple(),
    },
}


@pytest.mark.parametrize("scraper", MATRIX.keys())
@pytest.mark.parametrize("mode", ["metadata", "tests", "contests"])
def test_scraper_offline_fixture_matrix(run_scraper_offline, scraper, mode):
    args = MATRIX[scraper][mode]
    rc, objs = run_scraper_offline(scraper, mode, *args)
    assert rc in (0, 1), f"Bad exit code {rc}"
    assert objs, f"No JSON output for {scraper}:{mode}"

    if mode == "metadata":
        model = MetadataResult.model_validate(objs[-1])
        assert model.success is True
        assert model.url
        assert len(model.problems) >= 1
        assert all(isinstance(p.id, str) and p.id for p in model.problems)
    elif mode == "contests":
        model = ContestListResult.model_validate(objs[-1])
        assert model.success is True
        assert len(model.contests) >= 1
    else:
        assert len(objs) >= 1, "No test objects returned"
        validated_any = False
        for obj in objs:
            if "success" in obj and "tests" in obj and "problem_id" in obj:
                tr = TestsResult.model_validate(obj)
                assert tr.problem_id != ""
                assert isinstance(tr.tests, list)
                assert hasattr(tr, "combined"), "Missing combined field"
                assert tr.combined is not None, "combined field is None"
                assert hasattr(tr.combined, "input"), "combined missing input"
                assert hasattr(tr.combined, "expected"), "combined missing expected"
                assert isinstance(tr.combined.input, str), "combined.input not string"
                assert isinstance(tr.combined.expected, str), (
                    "combined.expected not string"
                )
                assert hasattr(tr, "multi_test"), "Missing multi_test field"
                assert isinstance(tr.multi_test, bool), "multi_test not boolean"
                validated_any = True
            else:
                assert "problem_id" in obj
                assert "tests" in obj and isinstance(obj["tests"], list)
                assert (
                    "timeout_ms" in obj and "memory_mb" in obj and "interactive" in obj
                )
                assert "combined" in obj, "Missing combined field in raw JSON"
                assert isinstance(obj["combined"], dict), "combined not a dict"
                assert "input" in obj["combined"], "combined missing input key"
                assert "expected" in obj["combined"], "combined missing expected key"
                assert isinstance(obj["combined"]["input"], str), (
                    "combined.input not string"
                )
                assert isinstance(obj["combined"]["expected"], str), (
                    "combined.expected not string"
                )
                assert "multi_test" in obj, "Missing multi_test field in raw JSON"
                assert isinstance(obj["multi_test"], bool), "multi_test not boolean"
                assert "precision" in obj, "Missing precision field in raw JSON"
                assert obj["precision"] is None or isinstance(
                    obj["precision"], float
                ), "precision must be None or float"
                validated_any = True
        assert validated_any, "No valid tests payloads validated"


def test_kattis_contest_metadata(run_scraper_offline):
    rc, objs = run_scraper_offline("kattis", "metadata", "open2024")
    assert rc == 0
    assert objs
    model = MetadataResult.model_validate(objs[-1])
    assert model.success is True
    assert len(model.problems) == 2
    assert model.contest_url != ""
    assert model.standings_url != ""


def test_usaco_precision_extracted(run_scraper_offline):
    rc, objs = run_scraper_offline("usaco", "tests", "dec24_gold")
    assert rc == 0
    precisions = [obj["precision"] for obj in objs if "problem_id" in obj]
    assert any(p is not None for p in precisions), (
        "Expected at least one problem with precision"
    )


@pytest.mark.parametrize(
    "scraper,contest_id",
    [
        ("cses", "nonexistent_category_xyz"),
        ("usaco", "badformat"),
        ("kattis", "nonexistent_problem_xyz"),
    ],
)
def test_scraper_metadata_error(run_scraper_offline, scraper, contest_id):
    rc, objs = run_scraper_offline(scraper, "metadata", contest_id)
    assert rc == 1
    assert objs
    assert objs[-1].get("success") is False
    assert objs[-1].get("error")


EXPECTED_PLATFORMS = {"atcoder", "codeforces", "cses", "usaco", "kattis", "codechef"}
EXPECTED_LANGUAGES = {"cpp", "python"}


def test_language_ids_coverage():
    assert set(LANGUAGE_IDS.keys()) == EXPECTED_PLATFORMS
    for platform in EXPECTED_PLATFORMS:
        for lang in EXPECTED_LANGUAGES:
            lid = get_language_id(platform, lang)
            assert lid is not None, f"Missing language ID: {platform}/{lang}"
            assert isinstance(lid, str) and lid, f"Empty language ID: {platform}/{lang}"


def test_language_ids_unknown_returns_none():
    assert get_language_id("codeforces", "rust") is None
    assert get_language_id("nonexistent", "cpp") is None

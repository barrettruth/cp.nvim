import pytest

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
                validated_any = True
        assert validated_any, "No valid tests payloads validated"

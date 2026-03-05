LANGUAGE_IDS = {
    "atcoder": {
        "cpp": "6017",
        "python": "6082",
    },
    "codeforces": {
        "cpp": "89",
        "python": "70",
    },
    "cses": {
        "cpp": "C++17",
        "python": "Python3",
    },
}


def get_language_id(platform: str, language: str) -> str | None:
    return LANGUAGE_IDS.get(platform, {}).get(language)

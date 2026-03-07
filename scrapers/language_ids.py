LANGUAGE_IDS = {
    "atcoder": {
        "cpp": "6017",
        "python": "6082",
        "java": "6056",
        "rust": "6088",
    },
    "codeforces": {
        "cpp": "89",
        "python": "70",
    },
    "cses": {
        "cpp": "C++17",
        "python": "Python3",
        "java": "Java",
        "rust": "Rust2021",
    },
    "usaco": {
        "cpp": "cpp",
        "python": "python",
        "java": "java",
    },
    "kattis": {
        "cpp": "C++",
        "python": "Python 3",
        "java": "Java",
        "rust": "Rust",
    },
    "codechef": {
        "cpp": "C++",
        "python": "PYTH 3",
        "java": "JAVA",
        "rust": "rust",
    },
}


def get_language_id(platform: str, language: str) -> str | None:
    return LANGUAGE_IDS.get(platform, {}).get(language)

#!/usr/bin/env python3
import subprocess
import sys


def main() -> None:
    argv = sys.argv[1:]
    max_iterations = 1000
    timeout = 10

    positional: list[str] = []
    i = 0
    while i < len(argv):
        if argv[i] == "--max-iterations" and i + 1 < len(argv):
            max_iterations = int(argv[i + 1])
            i += 2
        elif argv[i] == "--timeout" and i + 1 < len(argv):
            timeout = int(argv[i + 1])
            i += 2
        else:
            positional.append(argv[i])
            i += 1

    if len(positional) != 3:
        print(
            "Usage: stress.py <generator> <brute> <candidate> "
            "[--max-iterations N] [--timeout S]",
            file=sys.stderr,
        )
        sys.exit(1)

    generator, brute, candidate = positional

    for iteration in range(1, max_iterations + 1):
        try:
            gen_result = subprocess.run(
                generator,
                capture_output=True,
                text=True,
                shell=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            print(
                f"[stress] generator timed out on iteration {iteration}",
                file=sys.stderr,
            )
            sys.exit(1)

        if gen_result.returncode != 0:
            print(
                f"[stress] generator failed on iteration {iteration} "
                f"(exit code {gen_result.returncode})",
                file=sys.stderr,
            )
            if gen_result.stderr:
                print(gen_result.stderr, file=sys.stderr, end="")
            sys.exit(1)

        test_input = gen_result.stdout

        try:
            brute_result = subprocess.run(
                brute,
                input=test_input,
                capture_output=True,
                text=True,
                shell=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            print(f"[stress] brute timed out on iteration {iteration}", file=sys.stderr)
            print(f"\n--- input ---\n{test_input}", end="")
            sys.exit(1)

        try:
            cand_result = subprocess.run(
                candidate,
                input=test_input,
                capture_output=True,
                text=True,
                shell=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            print(
                f"[stress] candidate timed out on iteration {iteration}",
                file=sys.stderr,
            )
            print(f"\n--- input ---\n{test_input}", end="")
            sys.exit(1)

        brute_out = brute_result.stdout.strip()
        cand_out = cand_result.stdout.strip()

        if brute_out != cand_out:
            print(f"[stress] mismatch on iteration {iteration}", file=sys.stderr)
            print(f"\n--- input ---\n{test_input}", end="")
            print(f"\n--- expected (brute) ---\n{brute_out}")
            print(f"\n--- actual (candidate) ---\n{cand_out}")
            sys.exit(1)

        print(f"[stress] iteration {iteration} OK", file=sys.stderr)

    print(
        f"[stress] all {max_iterations} iterations passed",
        file=sys.stderr,
    )
    sys.exit(0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
import asyncio
import shlex
import sys
from collections.abc import Sequence


async def pump(
    reader: asyncio.StreamReader, writer: asyncio.StreamWriter | None
) -> None:
    while True:
        data = await reader.readline()
        if not data:
            break
        _ = sys.stdout.buffer.write(data)
        _ = sys.stdout.flush()
        if writer:
            writer.write(data)
            await writer.drain()


async def main(interactor_cmd: Sequence[str], interactee_cmd: Sequence[str]) -> None:
    interactor = await asyncio.create_subprocess_exec(
        *interactor_cmd,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
    )
    interactee = await asyncio.create_subprocess_exec(
        *interactee_cmd,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
    )

    assert (
        interactor.stdout
        and interactor.stdin
        and interactee.stdout
        and interactee.stdin
    )

    tasks = [
        asyncio.create_task(pump(interactor.stdout, interactee.stdin)),
        asyncio.create_task(pump(interactee.stdout, interactor.stdin)),
    ]
    _ = await asyncio.wait(tasks, return_when=asyncio.ALL_COMPLETED)
    _ = await interactor.wait()
    _ = await interactee.wait()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: interact.py <interactor> <interactee>", file=sys.stderr)
        sys.exit(1)

    interactor_cmd = shlex.split(sys.argv[1])
    interactee_cmd = shlex.split(sys.argv[2])

    _ = asyncio.run(main(interactor_cmd, interactee_cmd))

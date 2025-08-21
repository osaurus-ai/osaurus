#!/usr/bin/env python3
"""
Benchmark local LLM servers (e.g., Ollama, LM Studio) via OpenAI-compatible
Chat Completions API. Measures TTFT (time-to-first-token), total latency, and
throughput (chars/sec, bytes/sec) under configurable concurrency.

Examples:
  python3 scripts/benchmark_models.py \
    --server "ollama|http://localhost:11434|llama3.1" \
    --server "lmstudio|http://localhost:1234|Meta-Llama-3.1-8B-Instruct" \
    --prompt "Explain the significance of the Turing Test in AI." \
    --prompt "Write a Python function for Fibonacci with memoization." \
    --iterations 5 --concurrency 4 --stream --max-tokens 512 \
    --output-prefix ./results/llm-bench --export json csv

Requires: httpx>=0.27.0
Install deps: pip install -r scripts/requirements-bench.txt
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import json
import os
import sys
import time
from dataclasses import dataclass, asdict
from typing import Any, Dict, List, Optional, Tuple

try:
    import httpx  # type: ignore
except Exception as exc:  # pragma: no cover
    print("This script requires the 'httpx' package. Install with:\n  pip install -r scripts/requirements-bench.txt", file=sys.stderr)
    raise


@dataclass
class ServerSpec:
    name: str
    base_url: str
    model: str

    def endpoint(self) -> str:
        # Normalize to ensure we always hit /v1/chat/completions
        base = self.base_url.rstrip("/")
        if base.endswith("/v1"):
            return f"{base}/chat/completions"
        if base.endswith("/v1/"):
            return f"{base}chat/completions"
        return f"{base}/v1/chat/completions"


@dataclass
class RequestConfig:
    temperature: float = 0.2
    max_tokens: int = 512
    stream: bool = True
    timeout_seconds: float = 60.0
    extra_json: Dict[str, Any] = None  # for vendor-specific options


@dataclass
class SingleResult:
    server: str
    model: str
    prompt_id: int
    iteration: int
    success: bool
    status_code: Optional[int]
    ttft_ms: Optional[float]
    total_ms: Optional[float]
    output_chars: int
    output_bytes: int
    error: Optional[str]


def parse_server_arg(arg: str) -> ServerSpec:
    try:
        name, base_url, model = arg.split("|", 2)
        return ServerSpec(name=name.strip(), base_url=base_url.strip(), model=model.strip())
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            "--server must be of the form 'name|base_url|model'"
        ) from exc


def percentile(values: List[float], p: float) -> float:
    if not values:
        return float("nan")
    values_sorted = sorted(values)
    k = (len(values_sorted) - 1) * p
    f = int(k)
    c = min(f + 1, len(values_sorted) - 1)
    if f == c:
        return values_sorted[int(k)]
    d0 = values_sorted[f] * (c - k)
    d1 = values_sorted[c] * (k - f)
    return d0 + d1


async def run_single_chat(
    client: httpx.AsyncClient,
    server: ServerSpec,
    prompt_id: int,
    iteration: int,
    prompt_text: str,
    cfg: RequestConfig,
) -> SingleResult:
    url = server.endpoint()

    payload: Dict[str, Any] = {
        "model": server.model,
        "messages": [
            {"role": "user", "content": prompt_text},
        ],
        "temperature": cfg.temperature,
        "max_tokens": cfg.max_tokens,
        "stream": bool(cfg.stream),
    }

    if cfg.extra_json:
        payload.update(cfg.extra_json)

    headers = {
        "Content-Type": "application/json",
        # Prefer SSE for streaming; JSON otherwise
        "Accept": "text/event-stream" if cfg.stream else "application/json",
        # Most local servers do not require auth; support env var if provided
    }
    api_key = os.environ.get("OPENAI_API_KEY")
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    ttft_ms: Optional[float] = None
    total_ms: Optional[float] = None
    output_chars: int = 0
    output_bytes: int = 0
    status_code: Optional[int] = None

    t0 = time.perf_counter()

    try:
        if cfg.stream:
            async with client.stream("POST", url, json=payload, headers=headers, timeout=cfg.timeout_seconds) as resp:
                status_code = resp.status_code
                # Iterate Server-Sent Events style lines
                first_token_emitted = False
                async for line in resp.aiter_lines():
                    if not line:
                        continue
                    if line.startswith("data: "):
                        data = line[6:].strip()
                    else:
                        # Some servers may not prefix with 'data: '
                        data = line.strip()

                    if data == "[DONE]":
                        break

                    try:
                        obj = json.loads(data)
                    except json.JSONDecodeError:
                        # Treat as raw content chunk
                        chunk_text = data
                    else:
                        # OpenAI-style delta path
                        choices = obj.get("choices") or []
                        if choices:
                            delta = choices[0].get("delta") or {}
                            chunk_text = delta.get("content", "") or ""
                        else:
                            # Fallback if vendor uses non-standard field
                            chunk_text = obj.get("content", "") or ""

                    if chunk_text:
                        if not first_token_emitted:
                            ttft_ms = (time.perf_counter() - t0) * 1000.0
                            first_token_emitted = True
                        output_chars += len(chunk_text)
                        output_bytes += len(chunk_text.encode("utf-8", errors="ignore"))

                total_ms = (time.perf_counter() - t0) * 1000.0
        else:
            resp = await client.post(url, json=payload, headers=headers, timeout=cfg.timeout_seconds)
            status_code = resp.status_code
            text = resp.text
            # Non-stream: TTFT ~ total
            total_ms = (time.perf_counter() - t0) * 1000.0
            ttft_ms = total_ms
            try:
                data = resp.json()
                if isinstance(data, dict):
                    choices = data.get("choices") or []
                    if choices:
                        msg = choices[0].get("message") or {}
                        content = msg.get("content", "") or ""
                        output_chars = len(content)
                        output_bytes = len(content.encode("utf-8", errors="ignore"))
                    else:
                        text = json.dumps(data)
                        output_chars = len(text)
                        output_bytes = len(text.encode("utf-8", errors="ignore"))
                else:
                    output_chars = len(text)
                    output_bytes = len(text.encode("utf-8", errors="ignore"))
            except Exception:
                output_chars = len(text)
                output_bytes = len(text.encode("utf-8", errors="ignore"))

        success = status_code is not None and 200 <= status_code < 300
        return SingleResult(
            server=server.name,
            model=server.model,
            prompt_id=prompt_id,
            iteration=iteration,
            success=success,
            status_code=status_code,
            ttft_ms=ttft_ms,
            total_ms=total_ms,
            output_chars=output_chars,
            output_bytes=output_bytes,
            error=None,
        )
    except Exception as exc:  # pragma: no cover
        total_ms = (time.perf_counter() - t0) * 1000.0
        return SingleResult(
            server=server.name,
            model=server.model,
            prompt_id=prompt_id,
            iteration=iteration,
            success=False,
            status_code=None,
            ttft_ms=ttft_ms,
            total_ms=total_ms,
            output_chars=output_chars,
            output_bytes=output_bytes,
            error=str(exc),
        )


async def run_benchmark(
    servers: List[ServerSpec],
    prompts: List[str],
    iterations: int,
    concurrency: int,
    cfg: RequestConfig,
) -> List[SingleResult]:
    semaphore = asyncio.Semaphore(concurrency)

    async with httpx.AsyncClient(http2=False) as client:
        tasks: List[asyncio.Task[SingleResult]] = []

        async def bound_request(srv: ServerSpec, pidx: int, it: int, prompt: str) -> SingleResult:
            async with semaphore:
                return await run_single_chat(client, srv, pidx, it, prompt, cfg)

        for srv in servers:
            for pidx, prompt in enumerate(prompts):
                for it in range(1, iterations + 1):
                    tasks.append(asyncio.create_task(bound_request(srv, pidx, it, prompt)))

        results: List[SingleResult] = []
        for coro in asyncio.as_completed(tasks):
            res = await coro
            results.append(res)

        return results


def aggregate(results: List[SingleResult]) -> Dict[Tuple[str, str], Dict[str, Any]]:
    groups: Dict[Tuple[str, str], List[SingleResult]] = {}
    for r in results:
        key = (r.server, r.model)
        groups.setdefault(key, []).append(r)

    summary: Dict[Tuple[str, str], Dict[str, Any]] = {}
    for key, items in groups.items():
        latencies = [i.total_ms for i in items if i.success and i.total_ms is not None]
        ttfts = [i.ttft_ms for i in items if i.success and i.ttft_ms is not None]
        out_chars = [i.output_chars for i in items if i.success]
        out_bytes = [i.output_bytes for i in items if i.success]
        success_rate = sum(1 for i in items if i.success) / max(1, len(items))

        total_ms_avg = sum(latencies) / len(latencies) if latencies else float("nan")
        ttft_ms_avg = sum(ttfts) / len(ttfts) if ttfts else float("nan")
        chars_avg = sum(out_chars) / len(out_chars) if out_chars else float("nan")
        bytes_avg = sum(out_bytes) / len(out_bytes) if out_bytes else float("nan")

        summary[key] = {
            "runs": len(items),
            "success_rate": success_rate,
            "ttft_ms_avg": ttft_ms_avg,
            "ttft_ms_p50": percentile(ttfts, 0.5) if ttfts else float("nan"),
            "ttft_ms_p95": percentile(ttfts, 0.95) if ttfts else float("nan"),
            "total_ms_avg": total_ms_avg,
            "total_ms_p50": percentile(latencies, 0.5) if latencies else float("nan"),
            "total_ms_p95": percentile(latencies, 0.95) if latencies else float("nan"),
            "output_chars_avg": chars_avg,
            "output_bytes_avg": bytes_avg,
            # Throughput estimates (average length divided by average latency)
            "chars_per_sec_avg": (chars_avg / (total_ms_avg / 1000.0)) if latencies else float("nan"),
            "bytes_per_sec_avg": (bytes_avg / (total_ms_avg / 1000.0)) if latencies else float("nan"),
        }

    return summary


def export_json(path_prefix: str, results: List[SingleResult], summary: Dict[Tuple[str, str], Dict[str, Any]]) -> str:
    results_path = f"{path_prefix}.results.json"
    summary_path = f"{path_prefix}.summary.json"

    with open(results_path, "w", encoding="utf-8") as f:
        json.dump([asdict(r) for r in results], f, ensure_ascii=False, indent=2)
    with open(summary_path, "w", encoding="utf-8") as f:
        # Convert tuple keys to strings
        friendly_summary = {f"{k[0]}|{k[1]}": v for k, v in summary.items()}
        json.dump(friendly_summary, f, ensure_ascii=False, indent=2)

    return summary_path


def export_csv(path_prefix: str, results: List[SingleResult]) -> str:
    csv_path = f"{path_prefix}.results.csv"
    fieldnames = list(asdict(results[0]).keys()) if results else [
        "server","model","prompt_id","iteration","success","status_code","ttft_ms","total_ms","output_chars","output_bytes","error"
    ]
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for r in results:
            writer.writerow(asdict(r))
    return csv_path


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Benchmark OpenAI-compatible local LLM servers")
    parser.add_argument(
        "--server",
        action="append",
        type=parse_server_arg,
        required=True,
        help="Server spec 'name|base_url|model'. Example: ollama|http://localhost:11434|llama3.1",
    )
    parser.add_argument(
        "--prompt",
        action="append",
        default=[],
        help="Prompt text. Can be repeated. If omitted, uses built-in samples.",
    )
    parser.add_argument(
        "--prompts-file",
        default=None,
        help="Path to a text file with one prompt per line.",
    )
    parser.add_argument("--iterations", type=int, default=3, help="Iterations per prompt per server")
    parser.add_argument("--concurrency", type=int, default=2, help="Max concurrent requests")
    parser.add_argument("--temperature", type=float, default=0.2, help="Sampling temperature")
    parser.add_argument("--max-tokens", type=int, default=512, help="Max tokens for completion (server-enforced)")
    parser.add_argument("--timeout", type=float, default=60.0, help="Request timeout in seconds")
    parser.add_argument("--no-stream", action="store_true", help="Disable streaming; TTFT ~= total")
    parser.add_argument(
        "--output-prefix",
        default="./llm-bench",
        help="Prefix path for outputs (without extension). Files: .results.json/.summary.json/.results.csv",
    )
    parser.add_argument(
        "--export",
        nargs="+",
        choices=["json", "csv"],
        default=["json", "csv"],
        help="Export formats",
    )
    parser.add_argument(
        "--extra-json",
        default=None,
        help="Extra JSON to include in requests (e.g., '{\"frequency_penalty\":0.0}')",
    )
    return parser.parse_args(argv)


def load_prompts(args: argparse.Namespace) -> List[str]:
    prompts: List[str] = []
    if args.prompts_file:
        with open(args.prompts_file, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    prompts.append(line)
    if args.prompt:
        prompts.extend(args.prompt)
    if not prompts:
        prompts = [
            "Explain the significance of the Turing Test in AI in 2-3 sentences.",
            "Write a Python function for Fibonacci using memoization.",
            "Summarize the benefits and drawbacks of static typing vs dynamic typing.",
        ]
    return prompts


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    servers: List[ServerSpec] = args.server
    prompts = load_prompts(args)

    if args.extra_json:
        try:
            extra_json = json.loads(args.extra_json)
            if not isinstance(extra_json, dict):
                raise ValueError("--extra-json must be a JSON object")
        except Exception as exc:
            print(f"Failed to parse --extra-json: {exc}", file=sys.stderr)
            return 2
    else:
        extra_json = None

    cfg = RequestConfig(
        temperature=args.temperature,
        max_tokens=args.max_tokens,
        stream=not args.no_stream,
        timeout_seconds=args.timeout,
        extra_json=extra_json,
    )

    print(f"Running benchmark against {len(servers)} server(s), {len(prompts)} prompt(s), {args.iterations} iteration(s) each, concurrency={args.concurrency}...")

    results: List[SingleResult] = asyncio.run(
        run_benchmark(servers, prompts, args.iterations, args.concurrency, cfg)
    )

    # Aggregate
    summary = aggregate(results)

    # Console summary
    print("\nSummary:")
    for (srv, model), stats in summary.items():
        print(f"- {srv} | {model}:")
        print(
            f"  success_rate={stats['success_rate']*100:.1f}%  "
            f"ttft_avg={stats['ttft_ms_avg']:.1f}ms  ttft_p50={stats['ttft_ms_p50']:.1f}ms  ttft_p95={stats['ttft_ms_p95']:.1f}ms  "
            f"total_avg={stats['total_ms_avg']:.1f}ms  p50={stats['total_ms_p50']:.1f}ms  p95={stats['total_ms_p95']:.1f}ms  "
            f"chars/s={stats['chars_per_sec_avg']:.1f}  bytes/s={stats['bytes_per_sec_avg']:.1f}"
        )

    # Exports
    os.makedirs(os.path.dirname(os.path.abspath(args.output_prefix)) or ".", exist_ok=True)
    if "json" in args.export:
        export_json(args.output_prefix, results, summary)
    if "csv" in args.export:
        export_csv(args.output_prefix, results)

    print(f"\nSaved artifacts with prefix: {args.output_prefix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())



#!/usr/bin/env python3
"""
Analyze Claude Code token usage from local session JSONL files.

Scans ~/.claude/projects/ for session transcripts, extracts usage data
per model (Opus/Sonnet/Haiku), and calculates estimated costs.

Usage:
    python3 analyze_usage.py [OPTIONS]

Options:
    --range <spec>       Time range: today, week, month, YYYY-MM-DD, or YYYY-MM-DD:YYYY-MM-DD
    --project <keyword>  Filter sessions by project path keyword
    --by-project         Group results by project
    --by-day             Group results by day
    --json               Output JSON instead of table
    --no-sessions        With --json: omit the per-session array (smaller payload)
"""

import json
import os
import sys
import argparse
import urllib.request
import time
from pathlib import Path
from datetime import datetime, timedelta, timezone
from collections import defaultdict
from typing import Optional, Dict, List

__version__ = "1.5.0"

# ---------------------------------------------------------------------------
# Model pricing
# ---------------------------------------------------------------------------
LITELLM_PRICING_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
PRICING_CACHE_PATH = Path.home() / ".claude" / "cache" / "litellm_pricing.json"
PRICING_CACHE_TTL = 86400  # 24 hours in seconds

# Fallback pricing (USD per million tokens) when LiteLLM is unavailable.
# Mirrors the latest public Anthropic list prices for Claude
# (Fable 5, Opus 4.6/4.7/4.8, Sonnet 4.6, Haiku 4.5). Keep in sync with class_candidates below.
FALLBACK_PRICING = {
    "fable":  {"input": 10.00, "output": 50.00, "cache_write": 12.50, "cache_write_1h": 20.00, "cache_read": 1.00},
    "opus":   {"input":  5.00, "output": 25.00, "cache_write":  6.25, "cache_write_1h": 10.00, "cache_read": 0.50},
    "sonnet": {"input":  3.00, "output": 15.00, "cache_write":  3.75, "cache_write_1h":  6.00, "cache_read": 0.30},
    "haiku":  {"input":  1.00, "output":  5.00, "cache_write":  1.25, "cache_write_1h":  2.00, "cache_read": 0.10},
}

EMOJI = {"fable": "\U0001f7e0", "opus": "\U0001f7e3", "sonnet": "\U0001f535", "haiku": "\U0001f7e2", "other": "⚪"}  # 🟠🟣🔵🟢⚪

# Canonical display/aggregation order for model classes. "other" covers non-Claude
# models (Kimi/Qwen/GLM …) run through base-URL overrides — it has no entry in
# MODEL_PRICING (each model is priced individually via lookup_model_pricing).
MODEL_CLASSES = ("fable", "opus", "sonnet", "haiku", "other")

# Runtime: populated by load_pricing()
MODEL_PRICING = {}        # model_class -> {input, output, cache_write, cache_read} (per million)
_LITELLM_RAW = {}         # full raw model_name -> pricing from LiteLLM
_PRICING_SOURCE = "fallback"

# Populated by scan_sessions — surfaced in JSON / text output so format drift
# (e.g. Claude Code changing how it splits content blocks) shows up as an
# anomaly in the inflation factor instead of silently skewing the numbers.
_SCAN_STATS = {
    "raw_usage_lines": 0,       # assistant-with-usage lines in range, pre-dedup
    "unique_messages": 0,       # unique message.id (or missing-id) lines kept
    "null_msg_id_lines": 0,     # lines without message.id AND without requestId — can't be deduped
    "usage_upgraded_lines": 0,  # repeat-id lines whose usage grew (streaming rewrites)
    "skipped_lines": 0,         # malformed lines skipped (bad JSON / unexpected types) — file keeps scanning
    "files_failed": 0,          # files skipped entirely due to I/O errors (open/read)
    "null_ts_lines": 0,         # usage lines without a parseable timestamp (bypass the range filter)
    "prefiltered_lines": 0,     # non-assistant lines skipped before json.loads (substring prefilter)
}


def _fetch_litellm_pricing() -> Optional[dict]:
    """Fetch pricing JSON from LiteLLM GitHub, with local file cache."""
    # Check local cache first
    if PRICING_CACHE_PATH.exists():
        age = time.time() - PRICING_CACHE_PATH.stat().st_mtime
        if age < PRICING_CACHE_TTL:
            try:
                with open(PRICING_CACHE_PATH, "r") as f:
                    return json.load(f)
            except Exception:
                pass

    # Fetch from remote
    try:
        req = urllib.request.Request(LITELLM_PRICING_URL, headers={"User-Agent": "local-cc-cost/1.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception:
        # Network failed (e.g. corporate proxy 502) — fall back to stale cache.
        # Rate-limit refetches: bump the stale cache's mtime so remaining TTL ≈ 1h,
        # letting the next runs within ~1 hour reuse it WITHOUT re-paying the
        # HTTP timeout on every single run.
        if PRICING_CACHE_PATH.exists():
            try:
                with open(PRICING_CACHE_PATH, "r") as f:
                    stale = json.load(f)
                try:
                    t = time.time() - (PRICING_CACHE_TTL - 3600)
                    os.utime(PRICING_CACHE_PATH, (t, t))
                except Exception:
                    pass  # mtime bump is best-effort; stale data is still good
                return stale
            except Exception:
                pass
        return None
    # Save to cache — atomic (temp file in same dir + os.replace), and a cache
    # WRITE failure must not discard the successfully fetched in-memory data.
    try:
        PRICING_CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = PRICING_CACHE_PATH.with_name(PRICING_CACHE_PATH.name + f".tmp{os.getpid()}")
        with open(tmp_path, "w") as f:
            json.dump(data, f)
        os.replace(tmp_path, PRICING_CACHE_PATH)
    except Exception:
        try:
            tmp_path.unlink(missing_ok=True)
        except Exception:
            pass
        pass  # proceed with in-memory pricing
    return data


def _per_token_to_per_million(cost_per_token: float) -> float:
    """Convert per-token cost to per-million-tokens cost."""
    return cost_per_token * 1_000_000


def _extract_litellm_entry(entry: dict) -> Optional[dict]:
    """Extract pricing from a LiteLLM entry into our format (per million tokens).

    Guards against malformed LiteLLM data (null / string / missing cost fields,
    e.g. qwen3.5-plus ships with input_cost_per_token=None): any non-numeric
    required field → return None → caller falls through to class fallback.
    """
    if not isinstance(entry, dict):
        return None
    inp = entry.get("input_cost_per_token")
    out = entry.get("output_cost_per_token")
    if not isinstance(inp, (int, float)) or not isinstance(out, (int, float)):
        return None
    cw = entry.get("cache_creation_input_token_cost")
    if not isinstance(cw, (int, float)):
        cw = inp * 1.25  # default: 1.25x input (5m TTL)
    # 1-hour cache write costs more (2x input). Claude Code + Opus 4.8 use the 1h tier
    # heavily; pricing it at the 5m rate under-reports cost. Default 2x input when absent.
    cw1h = entry.get("cache_creation_input_token_cost_above_1hr")
    if not isinstance(cw1h, (int, float)):
        cw1h = inp * 2.0
    cr = entry.get("cache_read_input_token_cost")
    if not isinstance(cr, (int, float)):
        cr = inp * 0.1                                             # default: 0.1x input
    return {
        "input":          _per_token_to_per_million(inp),
        "output":         _per_token_to_per_million(out),
        "cache_write":    _per_token_to_per_million(cw),
        "cache_write_1h": _per_token_to_per_million(cw1h),
        "cache_read":     _per_token_to_per_million(cr),
    }


def load_pricing():
    """Load pricing from LiteLLM (with cache) or fall back to hardcoded values.

    Class-level representative pricing is picked *dynamically* by scanning LiteLLM
    for the newest canonical Claude model of each class, so new releases
    (e.g. Opus 4.8) are handled automatically without editing this file.
    """
    global MODEL_PRICING, _LITELLM_RAW, _PRICING_SOURCE

    raw = _fetch_litellm_pricing()
    if not raw:
        _PRICING_SOURCE = "fallback"
        MODEL_PRICING.update(FALLBACK_PRICING)
        return

    _LITELLM_RAW = raw
    _PRICING_SOURCE = "litellm"

    # Dynamic representative: scan LiteLLM for `claude-<class>-<major>[-<minor>]`
    # and pick the newest by (major, minor). Pure-canonical form only
    # (no provider prefixes, no date suffix) to avoid picking regional variants.
    # Minor is capped to 1–2 digits so a date-suffixed legacy key like
    # `claude-opus-4-20250514` (minor=20250514) doesn't outrank `claude-opus-4-7`.
    # Minor is optional because newer tiers drop it entirely (`claude-fable-5`).
    import re as _re
    pat = _re.compile(r"^claude-(fable|opus|sonnet|haiku)-(\d+)(?:-(\d{1,2}))?$")
    newest: dict[str, tuple[tuple[int, int], str]] = {}
    for key in raw.keys():
        m = pat.match(key)
        if not m:
            continue
        cls, major = m.group(1), int(m.group(2))
        minor = int(m.group(3)) if m.group(3) else 0
        ver = (major, minor)
        if cls not in newest or ver > newest[cls][0]:
            newest[cls] = (ver, key)

    for cls in ("fable", "opus", "sonnet", "haiku"):
        picked = newest.get(cls)
        if picked:
            pricing = _extract_litellm_entry(raw[picked[1]])
            if pricing:
                MODEL_PRICING[cls] = pricing
                continue
        MODEL_PRICING[cls] = FALLBACK_PRICING[cls]


def _normalize_model_name(model_str: str) -> str:
    """Turn a CC/Bedrock model string into a canonical LiteLLM key candidate.

    Examples:
        aws.claude-opus-4.7                 -> claude-opus-4-7
        us.anthropic.claude-opus-4-7-v1:0   -> claude-opus-4-7
        bedrock/claude-sonnet-4.6           -> claude-sonnet-4-6
        vertex_ai/claude-opus-4.7@default   -> claude-opus-4-7
        claude-fable-5[1m]                  -> claude-fable-5
    """
    if not model_str:
        return ""
    import re as _re
    s = model_str.strip()
    # Strip bracketed context-window markers like `[1m]` (Claude Code appends
    # these for long-context sessions; LiteLLM keys don't carry them).
    s = _re.sub(r"\[\w+\]$", "", s)
    # Strip `provider/` or `provider.` prefixes, keeping only the last segment.
    for sep in ("/", "."):
        while sep in s:
            head, tail = s.split(sep, 1)
            if head.lower() in (
                "aws", "anthropic", "bedrock", "vertex_ai", "azure_ai", "perplexity",
                "us", "eu", "au", "apac", "global",
            ):
                s = tail
            else:
                break
    # Strip Bedrock version suffixes like `-v1:0` or `@default`
    s = s.split("@", 1)[0]
    s = _re_sub_version_suffix(s)
    # Convert remaining dots inside the name to hyphens (e.g. 4.7 -> 4-7)
    s = s.replace(".", "-")
    return s


def _re_sub_version_suffix(s: str) -> str:
    import re as _re
    return _re.sub(r"-v\d+:\d+$", "", s)


def lookup_model_pricing(model_str: str) -> Optional[dict]:
    """Try to find exact pricing for a specific model name from LiteLLM data."""
    if not _LITELLM_RAW or not model_str:
        return None
    # 1. Exact match
    if model_str in _LITELLM_RAW:
        return _extract_litellm_entry(_LITELLM_RAW[model_str])
    # 2. Normalized canonical form (strip provider prefix, dot→hyphen, strip version suffix)
    norm = _normalize_model_name(model_str)
    if norm and norm in _LITELLM_RAW:
        return _extract_litellm_entry(_LITELLM_RAW[norm])
    # 3. Try prefixed variants. Try BOTH the original string and the normalized form,
    # because Claude entries use hyphens (`claude-opus-4-7`) but non-Claude providers
    # often keep dots (`azure_ai/kimi-k2.5`).
    prefixes = ("bedrock/", "vertex_ai/", "anthropic/",
                "azure_ai/", "moonshotai/", "openrouter/")
    candidates = {model_str}
    if norm:
        candidates.add(norm)
    for c in candidates:
        # strip leading provider segment from the raw string too
        bare = c.split(".", 1)[-1] if "." in c and c.split(".", 1)[0].lower() in (
            "aws", "anthropic", "bedrock", "vertex_ai", "azure_ai", "us", "eu", "au") else c
        for prefix in prefixes:
            key = prefix + bare
            if key in _LITELLM_RAW:
                return _extract_litellm_entry(_LITELLM_RAW[key])
    # 4. Last resort: substring suffix match. Walk LiteLLM keys once looking for any
    # key that ENDS with `/{candidate}` or `.{candidate}`. Covers region-specific
    # Bedrock entries like `bedrock/ap-northeast-1/moonshotai.kimi-k2.5`.
    for c in candidates:
        suffix1 = "/" + c
        suffix2 = "." + c
        for key in _LITELLM_RAW:
            if key.endswith(suffix1) or key.endswith(suffix2):
                pricing = _extract_litellm_entry(_LITELLM_RAW[key])
                if pricing:
                    return pricing
    return None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def classify_model(model_str: str) -> str:
    """Classify a model identifier string into fable/opus/sonnet/haiku/other.

    `other` covers non-Claude models the user runs through Claude Code via
    ANTHROPIC_BASE_URL overrides (Kimi, Qwen, GLM, …). Those get real pricing
    from LiteLLM via `lookup_model_pricing`; this classification is only used
    as a bucket for aggregation and a fallback for when LiteLLM doesn't know
    the model at all.
    """
    if not model_str:
        return "sonnet"
    m = model_str.lower()
    if "fable" in m:
        return "fable"
    if "opus" in m:
        return "opus"
    if "haiku" in m:
        return "haiku"
    if "sonnet" in m:
        return "sonnet"
    # Non-Claude models that show up via base-URL overrides
    for marker in ("kimi", "qwen", "glm", "deepseek", "moonshot", "yi-", "mistral",
                   "gpt-", "gemini", "llama"):
        if marker in m:
            return "other"
    # Unknown — default to sonnet bucket for aggregation but trust per-message
    # pricing to be correct (cost_for_message still tries lookup_model_pricing first).
    return "sonnet"


def parse_iso_ts(ts_str) -> Optional[datetime]:
    """Parse an ISO-8601 timestamp string to a timezone-aware datetime."""
    if not ts_str or not isinstance(ts_str, str):
        return None
    try:
        return datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
    except Exception:
        return None


def _line_may_lower_first_ts(line: str, current_min: datetime) -> bool:
    """Conservative substring check used by the scan prefilter: could this raw
    JSONL line's top-level "timestamp" be earlier than current_min?

    Scans every '"timestamp":"<value>"' occurrence in the raw line. The
    top-level key is necessarily among them: an unescaped '"timestamp":"'
    cannot occur *inside* a JSON string value (quotes there are always
    escaped as \\"), so every match is a real key — possibly nested, which
    only makes the check conservative. Returns True if any occurrence parses
    to a datetime earlier than current_min (caller then does the full
    json.loads; the existing top-level logic decides). A nested-key false
    positive costs one json.loads; there are no false negatives, because the
    top-level value is always inspected. Lines with no string-valued
    timestamp return False — the old full-parse path got None for them too.
    """
    for key in ('"timestamp":"', '"timestamp": "'):
        start = line.find(key)
        while start != -1:
            vstart = start + len(key)
            vend = line.find('"', vstart)
            if vend == -1:
                return True  # truncated/odd line — let the full parser judge
            ts = parse_iso_ts(line[vstart:vend])
            if ts is not None and ts < current_min:
                return True
            start = line.find(key, vend)
    return False


def cost_for_message(usage: dict, model_str: str) -> float:
    """Compute cost for a single API response, using LiteLLM's exact-model price when possible.

    Falls back to class-level MODEL_PRICING (populated from LiteLLM or FALLBACK_PRICING).
    This is the canonical cost function — always prefer this over recomputing from
    aggregated totals, since aggregation mixes multiple model names within a class
    (e.g. opus-4-6 and opus-4-7) whose prices may differ in future releases.
    """
    p = lookup_model_pricing(model_str)
    if p is None:
        cls = classify_model(model_str)
        p = MODEL_PRICING.get(cls, FALLBACK_PRICING.get(cls, FALLBACK_PRICING["sonnet"]))
    # Cache creation splits into a 1-hour tier (pricier) and the default 5-minute tier.
    # `cache_write` holds total creation tokens; `cache_write_1h` the 1h subset.
    cw_1h = usage.get("cache_write_1h", 0)
    cw_5m = max(0, usage["cache_write"] - cw_1h)
    cw_1h_price = p.get("cache_write_1h", p["cache_write"])  # older pricing dicts lack 1h
    return (
        usage["input_tokens"]  * p["input"]       / 1_000_000
      + usage["output_tokens"] * p["output"]      / 1_000_000
      + cw_5m                  * p["cache_write"] / 1_000_000
      + cw_1h                  * cw_1h_price      / 1_000_000
      + usage["cache_read"]    * p["cache_read"]  / 1_000_000
    )


def empty_usage() -> dict:
    return {"input_tokens": 0, "output_tokens": 0, "cache_write": 0, "cache_read": 0, "messages": 0, "cost": 0.0}


def add_usage(target: dict, source: dict):
    for k in ("input_tokens", "output_tokens", "cache_write", "cache_read", "messages"):
        target[k] += source[k]
    target["cost"] = target.get("cost", 0.0) + source.get("cost", 0.0)


def fmt(n: int) -> str:
    """Human-readable token count."""
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}m"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)


def fmt_full(n: int) -> str:
    return f"{n:,}"


def aggregate_group(model_usages: dict) -> dict:
    """Aggregate token counts (and pre-computed cost) across all models in a group."""
    agg = {"input_tokens": 0, "output_tokens": 0, "cache_write": 0, "cache_read": 0, "messages": 0, "cost": 0.0}
    for mu in model_usages.values():
        for k in ("input_tokens", "output_tokens", "cache_write", "cache_read", "messages"):
            agg[k] += mu[k]
        agg["cost"] += mu.get("cost", 0.0)
    agg["total"] = agg["input_tokens"] + agg["output_tokens"] + agg["cache_write"] + agg["cache_read"]
    return agg


def pricing_source_line() -> str:
    """Return a one-line string describing where pricing data comes from."""
    if _PRICING_SOURCE == "litellm":
        cache_age = ""
        if PRICING_CACHE_PATH.exists():
            age_s = time.time() - PRICING_CACHE_PATH.stat().st_mtime
            if age_s < 60:
                cache_age = "just now"
            elif age_s < 3600:
                cache_age = f"{int(age_s / 60)}m ago"
            else:
                cache_age = f"{int(age_s / 3600)}h ago"
        return f"💲 定价来源: LiteLLM (cached {cache_age})"
    return "💲 定价来源: 内置 fallback 定价"


def scan_diagnostics() -> dict:
    """Return the current scan's self-diagnostic counters + inflation factor.

    `inflation_factor` = raw_usage_lines / unique_messages, where raw is how many
    assistant-with-usage lines sat in the requested time range before dedup.
    Claude Code writes one JSONL line per content block of each API response,
    so healthy values cluster around 1.5–3x. A drop to ~1.0 suggests Claude
    Code changed its JSONL format and dedup may no longer be necessary; a
    spike above 5x suggests a new repeat pattern worth investigating.
    """
    raw = _SCAN_STATS["raw_usage_lines"]
    uniq = _SCAN_STATS["unique_messages"]
    return {
        "raw_usage_lines": raw,
        "unique_messages": uniq,
        "null_msg_id_lines": _SCAN_STATS["null_msg_id_lines"],
        "usage_upgraded_lines": _SCAN_STATS["usage_upgraded_lines"],
        "skipped_lines": _SCAN_STATS["skipped_lines"],
        "files_failed": _SCAN_STATS["files_failed"],
        "null_ts_lines": _SCAN_STATS["null_ts_lines"],
        "prefiltered_lines": _SCAN_STATS["prefiltered_lines"],
        "inflation_factor": round(raw / uniq, 3) if uniq else None,
    }


def diagnostics_line() -> str:
    d = scan_diagnostics()
    if not d["unique_messages"]:
        return ""
    flag = ""
    f = d["inflation_factor"] or 0
    if f >= 5.0:
        flag = "  ⚠️ unusually high (format change?)"
    elif f <= 1.05:
        flag = "  ℹ️ near 1.0 — dedup had little effect (direct API or new format)"
    nulls = f"  null_ids={d['null_msg_id_lines']}" if d["null_msg_id_lines"] else ""
    upgraded = f"  usage_upgraded={d['usage_upgraded_lines']}" if d["usage_upgraded_lines"] else ""
    skipped = f"  skipped_lines={d['skipped_lines']}" if d["skipped_lines"] else ""
    failed = f"  files_failed={d['files_failed']}" if d["files_failed"] else ""
    null_ts = f"  null_ts={d['null_ts_lines']}" if d["null_ts_lines"] else ""
    prefiltered = f"  prefiltered={d['prefiltered_lines']}" if d["prefiltered_lines"] else ""
    return f"🔬 扫描自检: 原始行={d['raw_usage_lines']}  去重后={d['unique_messages']}  inflation={f}x{nulls}{upgraded}{skipped}{failed}{null_ts}{prefiltered}{flag}"


def friendly_project(raw: str) -> str:
    """Turn the escaped project directory name into something readable."""
    return (
        raw
        .replace("-Users-lijiakun-Documents-project-", "")
        .replace("-Users-lijiakun-Documents-", "~/")
        .replace("-Users-lijiakun", "~")
    )


# ---------------------------------------------------------------------------
# Time range parsing
# ---------------------------------------------------------------------------
def _parse_range_date(s: str) -> datetime:
    """Parse one --range date bound; exit(2) with a clear error on bad input."""
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        print(f"Error: invalid --range date '{s}' (expected today, week, month, "
              f"YYYY-MM-DD, or YYYY-MM-DD:YYYY-MM-DD)", file=sys.stderr)
        sys.exit(2)


def resolve_range(spec: str):
    """Return (start_date, end_date) as naive local datetimes."""
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    if spec == "today":
        return today, today + timedelta(days=1)
    if spec == "week":
        monday = today - timedelta(days=today.weekday())
        return monday, today + timedelta(days=1)
    if spec == "month":
        first = today.replace(day=1)
        return first, today + timedelta(days=1)
    if ":" in spec:
        parts = spec.split(":")
        if len(parts) != 2:
            print(f"Error: invalid --range '{spec}' (expected YYYY-MM-DD:YYYY-MM-DD)", file=sys.stderr)
            sys.exit(2)
        start = _parse_range_date(parts[0])
        end = _parse_range_date(parts[1])
        if start > end:
            print(f"Error: --range start '{parts[0]}' is after end '{parts[1]}'", file=sys.stderr)
            sys.exit(2)
        # end bound is exclusive (+1 day), so start == end is a valid single-day range
        return start, end + timedelta(days=1)
    # Single date
    d = _parse_range_date(spec)
    return d, d + timedelta(days=1)


# ---------------------------------------------------------------------------
# Core analysis
# ---------------------------------------------------------------------------
def scan_sessions(projects_dir: Path, start_dt: datetime, end_dt: datetime, project_filter: Optional[str]):
    """Scan all JSONL files and return structured session data."""
    start_epoch = start_dt.timestamp()
    end_epoch = end_dt.timestamp()

    # Reset diagnostic counters for this scan
    for _k in _SCAN_STATS:
        _SCAN_STATS[_k] = 0

    # Convert local-time range boundaries to UTC for comparing with message timestamps.
    # astimezone() on a naive datetime attaches the system local zone *per datetime*,
    # so DST transitions inside/across the range resolve correctly (a frozen
    # "current offset" would shift boundaries by an hour across DST changes).
    start_utc = start_dt.astimezone(timezone.utc)
    end_utc = end_dt.astimezone(timezone.utc)

    # Collect JSONL files that might contain in-range messages.
    # Lower bound: skip files last modified BEFORE the range start (no writes after
    # start ⇒ no in-range content). Do NOT skip on mtime after the range end —
    # cross-day sessions may have mtime beyond the range but still contain
    # in-range messages.
    all_files: list[dict] = []
    for p in projects_dir.rglob("*.jsonl"):
        try:
            st = p.stat()
        except OSError:
            # Deleted mid-scan or dangling symlink — skip, don't kill the scan
            continue
        if st.st_mtime < start_epoch:
            continue
        # Upper bound: peek the first line's timestamp — content is authoritative.
        # st_birthtime is only a cheap pre-filter to decide whether the peek is
        # worth doing: rsync/cp/migration resets birthtime to the copy date, so a
        # birthtime after the range end does NOT prove the content is out of range.
        # For current-month queries the end is in the future, so the peek almost
        # never runs. Conservative: when in doubt, scan the file.
        birthtime = getattr(st, "st_birthtime", None)
        if birthtime is None or birthtime > end_epoch:
            try:
                with open(p, "r") as _f:
                    _first = json.loads(_f.readline())
                _first_ts = parse_iso_ts(_first.get("timestamp")) if isinstance(_first, dict) else None
                if _first_ts and _first_ts >= end_utc:
                    continue
            except Exception:
                pass  # unreadable/odd first line — scan the file anyway
        # Subagent transcripts live at <session-id>/subagents/agent-*.jsonl. Match the
        # path *component*, not a substring — a project dir literally named
        # "my-subagents-tool" must not false-positive.
        is_sub = p.parent.name == "subagents"
        parent_session = p.parent.parent.name if is_sub else p.stem
        project_raw = p.parent.parent.parent.name if is_sub else p.parent.name
        if project_filter and project_filter.lower() not in project_raw.lower():
            continue
        all_files.append({
            "path": p,
            "is_subagent": is_sub,
            "session_id": parent_session,
            "project_raw": project_raw,
        })

    # Aggregate per session → per model
    sessions: dict[str, dict] = {}
    # Global dedup: Anthropic message.id is unique per API call, but Claude Code
    # writes one JSONL line per content block (thinking / text / tool_use …), each
    # carrying the same `message.usage`. Without dedup, a response with N blocks
    # is counted N times — inflating tokens and cost by ~1.5–3x.
    # The usage is NOT identical across those lines though: output_tokens grows
    # with streaming progress (first line often 1, last line the real value), so
    # each id keeps its counted usage + the aggregation buckets it landed in,
    # letting later lines back-fill the delta.
    seen_msgs: dict[str, dict] = {}
    for finfo in all_files:
        sid = finfo["session_id"]
        if sid not in sessions:
            sessions[sid] = {
                "project_raw": finfo["project_raw"],
                "project": friendly_project(finfo["project_raw"]),
                "first_msg": "",
                "first_ts": None,
                "models": defaultdict(empty_usage),
                "daily_models": defaultdict(lambda: defaultdict(empty_usage)),
            }

        # File-level fallback is deliberately narrow (I/O errors only): one malformed
        # *line* must not discard the rest of the file's usage. Per-line problems are
        # counted in skipped_lines below and the file keeps scanning.
        # errors="replace": invalid UTF-8 bytes become U+FFFD instead of raising
        # UnicodeDecodeError mid-iteration (which would escape the per-line handler
        # and crash the whole scan); the mangled line then fails json.loads and is
        # counted in skipped_lines while the rest of the file survives.
        try:
            sdata = sessions[sid]
            is_sub = finfo["is_subagent"]
            with open(finfo["path"], "r", errors="replace") as f:
                for line in f:
                    if not line.strip():
                        continue
                    # Assistant-line prefilter: ~57% of lines (74% of bytes) are
                    # non-assistant, and the only things non-assistant lines
                    # contribute are session metadata: first_msg (user lines,
                    # main-session files only) and first_ts (min over all
                    # lines' top-level timestamps). The gate is data-driven,
                    # not order-lucky: every line is fully parsed until
                    # first_msg is captured (subagent files never contribute
                    # it) and first_ts is set; after that a non-assistant line
                    # is skipped only if _line_may_lower_first_ts proves its
                    # timestamp cannot lower the running min (Claude Code
                    # writes the first burst of lines with ~200ms out-of-order
                    # jitter, so "metadata already captured" alone is not
                    # sufficient — measured on real data).
                    # Invariant: Claude Code writes compact JSON where
                    # '"type":"assistant"' appears verbatim in assistant lines;
                    # the spaced variant covers a non-compact encoder. If the
                    # format ever drifts so assistant lines fail this substring
                    # test, raw_usage_lines/unique_messages collapse toward 0
                    # and inflation_factor toward None — visible in diagnostics —
                    # while prefiltered_lines (counted here) shows the skip
                    # volume.
                    if ((is_sub or sdata["first_msg"])
                            and sdata["first_ts"] is not None
                            and '"type":"assistant"' not in line
                            and '"type": "assistant"' not in line
                            and not _line_may_lower_first_ts(line, sdata["first_ts"])):
                        _SCAN_STATS["prefiltered_lines"] += 1
                        continue
                    try:
                        data = json.loads(line)
                        if not isinstance(data, dict):
                            _SCAN_STATS["skipped_lines"] += 1
                            continue

                        # Capture first user message (main session only)
                        if not finfo["is_subagent"] and not sessions[sid]["first_msg"]:
                            if data.get("type") == "user" and "message" in data:
                                msg = data["message"]
                                if isinstance(msg, dict):
                                    content = msg.get("content", "")
                                    if isinstance(content, list):
                                        for part in content:
                                            if isinstance(part, dict) and part.get("type") == "text":
                                                sessions[sid]["first_msg"] = part.get("text", "")[:50]
                                                break
                                    elif isinstance(content, str):
                                        sessions[sid]["first_msg"] = content[:50]
                                elif isinstance(msg, str):
                                    sessions[sid]["first_msg"] = msg[:50]

                        # Timestamp
                        ts = parse_iso_ts(data.get("timestamp"))
                        if ts and (sessions[sid]["first_ts"] is None or ts < sessions[sid]["first_ts"]):
                            sessions[sid]["first_ts"] = ts

                        # Usage from assistant messages
                        if data.get("type") == "assistant" and "message" in data:
                            m = data["message"]
                            if not isinstance(m, dict):
                                _SCAN_STATS["skipped_lines"] += 1
                                continue
                            usage_raw = m.get("usage") or {}
                            if not isinstance(usage_raw, dict):
                                _SCAN_STATS["skipped_lines"] += 1
                                continue
                            inp = int(usage_raw.get("input_tokens") or 0)
                            out = int(usage_raw.get("output_tokens") or 0)
                            if not inp and not out:
                                continue
                            # Filter: only count messages whose timestamp falls within the requested range
                            if ts:
                                if ts < start_utc or ts >= end_utc:
                                    continue
                            else:
                                # No parseable timestamp — keep the line (excluding it
                                # would under-count) but track it for diagnostics.
                                _SCAN_STATS["null_ts_lines"] += 1
                            _SCAN_STATS["raw_usage_lines"] += 1
                            cw = int(usage_raw.get("cache_creation_input_tokens") or 0)
                            cr = int(usage_raw.get("cache_read_input_tokens") or 0)
                            # 1-hour cache tier (priced higher than 5m). Newer Claude Code +
                            # Opus 4.8 put most cache creation here; needed for correct cost.
                            cc_detail = usage_raw.get("cache_creation") or {}
                            if not isinstance(cc_detail, dict):
                                cc_detail = {}
                            cw_1h = int(cc_detail.get("ephemeral_1h_input_tokens") or 0)
                            cw_5m = int(cc_detail.get("ephemeral_5m_input_tokens") or 0)
                            # Top-level field is occasionally 0 while the detail breakdown is
                            # populated; trust whichever is larger.
                            cw = max(cw, cw_5m + cw_1h)
                            # Dedup by message.id (see comment at top of this function).
                            # Fallback: lines missing message.id but carrying a requestId
                            # dedup on that instead (same max/delta mechanics).
                            msg_id = m.get("id")
                            if not msg_id and data.get("requestId"):
                                msg_id = "req:" + str(data["requestId"])
                            if msg_id and msg_id in seen_msgs:
                                # Same message.id seen again: output_tokens grows as the
                                # response streams (later lines carry the larger, truer value).
                                # Take the per-field max and back-fill the delta into the
                                # buckets this message was originally counted in.
                                rec = seen_msgs[msg_id]
                                u = rec["usage"]
                                new_u = {
                                    "input_tokens": max(u["input_tokens"], inp),
                                    "output_tokens": max(u["output_tokens"], out),
                                    "cache_write": max(u["cache_write"], cw),
                                    "cache_write_1h": max(u["cache_write_1h"], cw_1h),
                                    "cache_read": max(u["cache_read"], cr),
                                }
                                if new_u != u:
                                    for field in ("input_tokens", "output_tokens", "cache_write", "cache_read"):
                                        delta = new_u[field] - u[field]
                                        rec["mu"][field] += delta
                                        rec["dmu"][field] += delta
                                    new_cost = cost_for_message(new_u, rec["model_str"])
                                    rec["mu"]["cost"] += new_cost - rec["cost"]
                                    rec["dmu"]["cost"] += new_cost - rec["cost"]
                                    rec["usage"] = new_u
                                    rec["cost"] = new_cost
                                    _SCAN_STATS["usage_upgraded_lines"] += 1
                                continue
                            if not msg_id:
                                _SCAN_STATS["null_msg_id_lines"] += 1
                            _SCAN_STATS["unique_messages"] += 1
                            model_str = m.get("model", "") or ""
                            model_cls = classify_model(model_str)
                            # Per-message cost using the exact model string (preferred over
                            # class-level pricing — avoids mis-pricing Opus 4.7 as Opus 4).
                            single = {"input_tokens": inp, "output_tokens": out, "cache_write": cw,
                                      "cache_write_1h": cw_1h, "cache_read": cr}
                            msg_cost = cost_for_message(single, model_str)
                            # Session-level aggregation
                            mu = sessions[sid]["models"][model_cls]
                            mu["messages"] += 1
                            mu["input_tokens"] += inp
                            mu["output_tokens"] += out
                            mu["cache_write"] += cw
                            mu["cache_read"] += cr
                            mu["cost"] += msg_cost
                            # Per-day aggregation (using message's own local date;
                            # astimezone() resolves the local zone per datetime → DST-safe)
                            if ts:
                                day_key = ts.astimezone().strftime("%Y-%m-%d")
                            elif sessions[sid]["first_ts"]:
                                day_key = sessions[sid]["first_ts"].astimezone().strftime("%Y-%m-%d")
                            else:
                                day_key = "unknown"
                            dmu = sessions[sid]["daily_models"][day_key][model_cls]
                            dmu["messages"] += 1
                            dmu["input_tokens"] += inp
                            dmu["output_tokens"] += out
                            dmu["cache_write"] += cw
                            dmu["cache_read"] += cr
                            dmu["cost"] += msg_cost
                            if msg_id:
                                seen_msgs[msg_id] = {
                                    "usage": single, "cost": msg_cost, "model_str": model_str,
                                    "mu": mu, "dmu": dmu,
                                }
                    except Exception:
                        # Malformed line (bad JSON / unexpected types) — count it and
                        # keep scanning the rest of the file.
                        _SCAN_STATS["skipped_lines"] += 1
                        continue
        except OSError:
            _SCAN_STATS["files_failed"] += 1
            continue

    # Drop sessions with no usage
    return {sid: s for sid, s in sessions.items() if any(
        u["messages"] > 0 for u in s["models"].values()
    )}


# ---------------------------------------------------------------------------
# Output formatters
# ---------------------------------------------------------------------------
def print_detail(sessions: dict, range_label: str):
    """Print per-session detail with per-model breakdown."""
    sorted_sessions = sorted(sessions.items(), key=lambda x: str(x[1].get("first_ts") or ""))

    print("=" * 115)
    print(f"\U0001f4ca Claude Code Token \u7528\u91cf\u5206\u6790 \u2014 {range_label}")
    print("=" * 115)

    grand_by_model: dict[str, dict] = defaultdict(empty_usage)

    for sid, sdata in sorted_sessions:
        session_cost = sum(u["cost"] for u in sdata["models"].values())
        date_str = sdata["first_ts"].strftime("%m/%d %H:%M") if sdata["first_ts"] else "N/A"
        first_msg = sdata["first_msg"] or "-"

        print(f"\n\U0001f539 {date_str}  {sdata['project']}/{sid[:8]}  \U0001f4b0${session_cost:.2f}")
        print(f"   \u300c{first_msg}\u300d")

        for mc in MODEL_CLASSES:
            if mc not in sdata["models"]:
                continue
            mu = sdata["models"][mc]
            c = mu["cost"]
            add_usage(grand_by_model[mc], mu)
            print(
                f"   {EMOJI[mc]} {mc:<8} msgs:{mu['messages']:>4}  "
                f"in:{fmt(mu['input_tokens']):>8}  out:{fmt(mu['output_tokens']):>8}  "
                f"cache_r:{fmt(mu['cache_read']):>8}  cache_w:{fmt(mu['cache_write']):>8}  "
                f"${c:.2f}"
            )

    # Grand totals
    print()
    print("=" * 115)
    print("\U0001f4cb \u603b\u8ba1 (\u6309\u6a21\u578b)")
    print("=" * 115)

    total_tokens = 0
    total_cost = 0.0
    for mc in MODEL_CLASSES:
        if mc not in grand_by_model:
            continue
        mu = grand_by_model[mc]
        c = mu["cost"]
        total_cost += c
        # "other" has no class-level representative price — each model in it is
        # priced individually via lookup_model_pricing during the scan.
        p = MODEL_PRICING.get(mc)
        price_note = (
            f"(Input ${p['input']}/M, Output ${p['output']}/M, CacheW ${p['cache_write']}/M, CacheR ${p['cache_read']}/M)"
            if p else "(按各模型 LiteLLM 实价计费)"
        )
        all_in = mu["input_tokens"] + mu["cache_write"] + mu["cache_read"]
        total_tokens += all_in + mu["output_tokens"]
        print(f"""
{EMOJI[mc]} {mc.upper()}  {price_note}
   \u6d88\u606f\u6570:         {fmt_full(mu['messages'])}
   Input:          {fmt_full(mu['input_tokens'])}
   Output:         {fmt_full(mu['output_tokens'])}
   Cache Write:    {fmt_full(mu['cache_write'])}
   Cache Read:     {fmt_full(mu['cache_read'])}
   \u8d39\u7528:           ${c:.2f}""")

    print(f"""
{'=' * 115}
\U0001f522 \u603b Tokens (\u542b\u7f13\u5b58):  {fmt_full(total_tokens)}
\U0001f4b0 \u9884\u4f30\u603b\u8d39\u7528:       ${total_cost:.2f}
{'=' * 115}
""")
    print(pricing_source_line())
    _d = diagnostics_line()
    if _d: print(_d)
    print("\u26a0\ufe0f  \u8d39\u7528\u57fa\u4e8e API \u516c\u5f00\u5b9a\u4ef7\u9884\u4f30\uff0c\u8ba2\u9605\u7528\u6237\u7684\u5b9e\u9645\u8ba1\u8d39\u65b9\u5f0f\u4e0d\u540c")


def print_by_project(sessions: dict, range_label: str):
    """Group and print results by project."""
    projects: dict[str, dict] = defaultdict(lambda: defaultdict(empty_usage))
    for sid, sdata in sessions.items():
        proj = sdata["project"]
        for mc, mu in sdata["models"].items():
            add_usage(projects[proj][mc], mu)

    print("=" * 100)
    print(f"\U0001f4ca \u6309\u9879\u76ee\u6c47\u603b \u2014 {range_label}")
    print("=" * 100)

    grand_cost = 0.0
    grand_agg = {"input_tokens": 0, "output_tokens": 0, "cache_write": 0, "cache_read": 0, "messages": 0, "total": 0}
    for proj in sorted(projects.keys()):
        proj_cost = sum(u["cost"] for u in projects[proj].values())
        agg = aggregate_group(projects[proj])
        grand_cost += proj_cost
        for k in grand_agg:
            grand_agg[k] += agg[k]
        print(f"\n\U0001f4c1 {proj}  \U0001f4b0${proj_cost:.2f}")
        print(f"   msgs:{agg['messages']}  in:{fmt(agg['input_tokens'])}  out:{fmt(agg['output_tokens'])}  "
              f"cache_r:{fmt(agg['cache_read'])}  cache_w:{fmt(agg['cache_write'])}  total:{fmt(agg['total'])}")
        for mc in MODEL_CLASSES:
            if mc not in projects[proj]:
                continue
            mu = projects[proj][mc]
            c = mu["cost"]
            print(
                f"   {EMOJI[mc]} {mc:<8} msgs:{mu['messages']:>4}  "
                f"in:{fmt(mu['input_tokens']):>8}  out:{fmt(mu['output_tokens']):>8}  "
                f"cache_r:{fmt(mu['cache_read']):>8}  cache_w:{fmt(mu['cache_write']):>8}  "
                f"${c:.2f}"
            )
    print(f"\n{'=' * 100}")
    print(f"\U0001f4cb \u603b\u8ba1:  msgs:{fmt_full(grand_agg['messages'])}  "
          f"in:{fmt(grand_agg['input_tokens'])}  out:{fmt(grand_agg['output_tokens'])}  "
          f"cache_r:{fmt(grand_agg['cache_read'])}  cache_w:{fmt(grand_agg['cache_write'])}  "
          f"total:{fmt(grand_agg['total'])}")
    print(f"\U0001f4b0 \u603b\u8d39\u7528: ${grand_cost:.2f}")
    print(pricing_source_line())
    _d = diagnostics_line()
    if _d: print(_d)
    print(f"{'=' * 100}")


def print_by_day(sessions: dict, range_label: str):
    """Group and print results by day."""
    days: dict[str, dict] = defaultdict(lambda: defaultdict(empty_usage))
    for sid, sdata in sessions.items():
        for day_key, day_models in sdata.get("daily_models", {}).items():
            for mc, mu in day_models.items():
                add_usage(days[day_key][mc], mu)

    print("=" * 100)
    print(f"\U0001f4ca \u6309\u5929\u6c47\u603b \u2014 {range_label}")
    print("=" * 100)

    grand_cost = 0.0
    grand_agg = {"input_tokens": 0, "output_tokens": 0, "cache_write": 0, "cache_read": 0, "messages": 0, "total": 0}
    for day in sorted(days.keys()):
        day_cost = sum(u["cost"] for u in days[day].values())
        agg = aggregate_group(days[day])
        grand_cost += day_cost
        for k in grand_agg:
            grand_agg[k] += agg[k]
        print(f"\n\U0001f4c5 {day}  \U0001f4b0${day_cost:.2f}")
        print(f"   msgs:{agg['messages']}  in:{fmt(agg['input_tokens'])}  out:{fmt(agg['output_tokens'])}  "
              f"cache_r:{fmt(agg['cache_read'])}  cache_w:{fmt(agg['cache_write'])}  total:{fmt(agg['total'])}")
        for mc in MODEL_CLASSES:
            if mc not in days[day]:
                continue
            mu = days[day][mc]
            c = mu["cost"]
            print(
                f"   {EMOJI[mc]} {mc:<8} msgs:{mu['messages']:>4}  "
                f"in:{fmt(mu['input_tokens']):>8}  out:{fmt(mu['output_tokens']):>8}  "
                f"cache_r:{fmt(mu['cache_read']):>8}  cache_w:{fmt(mu['cache_write']):>8}  "
                f"${c:.2f}"
            )
    print(f"\n{'=' * 100}")
    print(f"\U0001f4cb \u603b\u8ba1:  msgs:{fmt_full(grand_agg['messages'])}  "
          f"in:{fmt(grand_agg['input_tokens'])}  out:{fmt(grand_agg['output_tokens'])}  "
          f"cache_r:{fmt(grand_agg['cache_read'])}  cache_w:{fmt(grand_agg['cache_write'])}  "
          f"total:{fmt(grand_agg['total'])}")
    print(f"\U0001f4b0 \u603b\u8d39\u7528: ${grand_cost:.2f}")
    print(pricing_source_line())
    _d = diagnostics_line()
    if _d: print(_d)
    print(f"{'=' * 100}")


def print_json(sessions: dict, subscription_quota: Optional[dict] = None,
               include_sessions: bool = True):
    """Output structured JSON."""
    result = {
        "script_version": __version__,
        "pricing_source": _PRICING_SOURCE,
        "model_pricing": {mc: p for mc, p in MODEL_PRICING.items()},
        "sessions": [],
        "totals_by_model": {},
        "grand_total_cost": 0.0,
    }
    grand_by_model: dict[str, dict] = defaultdict(empty_usage)

    for sid, sdata in sessions.items():
        if not include_sessions:
            # --no-sessions: skip building the heavy per-session entries, but
            # still accumulate the per-model totals they would have fed.
            for mc, mu in sdata["models"].items():
                add_usage(grand_by_model[mc], mu)
            continue
        s_entry = {
            "session_id": sid,
            "project": sdata["project"],
            "first_message": sdata["first_msg"],
            "timestamp": sdata["first_ts"].isoformat() if sdata["first_ts"] else None,
            "models": {},
            "total_cost": 0.0,
        }
        for mc, mu in sdata["models"].items():
            c = mu["cost"]
            s_entry["models"][mc] = {**mu, "cost": round(c, 4)}
            s_entry["total_cost"] += c
            add_usage(grand_by_model[mc], mu)
        s_entry["total_cost"] = round(s_entry["total_cost"], 4)
        result["sessions"].append(s_entry)

    total = 0.0
    for mc, mu in grand_by_model.items():
        c = mu["cost"]
        total += c
        result["totals_by_model"][mc] = {**mu, "cost": round(c, 4)}
    result["grand_total_cost"] = round(total, 4)

    # Per-day breakdown using message-level timestamps (not session start time)
    days: dict[str, dict] = defaultdict(lambda: defaultdict(empty_usage))
    for sid, sdata in sessions.items():
        for day_key, day_models in sdata.get("daily_models", {}).items():
            for mc, mu in day_models.items():
                add_usage(days[day_key][mc], mu)

    result["daily_breakdown"] = {}
    for day_key in sorted(days.keys()):
        day_entry: dict = {"models": {}, "total_cost": 0.0}
        for mc, mu in days[day_key].items():
            c = mu["cost"]
            day_entry["models"][mc] = {**mu, "cost": round(c, 4)}
            day_entry["total_cost"] += c
        day_entry["total_cost"] = round(day_entry["total_cost"], 4)
        result["daily_breakdown"][day_key] = day_entry

    result["diagnostics"] = scan_diagnostics()

    if not include_sessions:
        del result["sessions"]

    if subscription_quota is not None:
        result["subscription_quota"] = subscription_quota

    print(json.dumps(result, indent=2, ensure_ascii=False, default=str))


# ---------------------------------------------------------------------------
# Subscription OAuth quota fetcher
# ---------------------------------------------------------------------------
# Anthropic exposes a private-but-documented OAuth endpoint at
#   GET https://api.anthropic.com/api/oauth/usage
# with header `anthropic-beta: oauth-2025-04-20`, that Claude Code itself uses
# to drive /status and usage reporting. Response shape:
#   { "five_hour":  {"utilization": 45, "resets_at": "..."},
#     "seven_day":  {"utilization": 32, "resets_at": "..."},
#     "extra_usage": {"is_enabled": bool, "used_credits": N, "monthly_limit": N} }
#
# This is ONLY meaningful for users who authenticated via `claude login`
# (subscription). API key users (Bedrock/Vertex/Console) have no OAuth token
# in `~/.claude/.credentials.json` and this function returns None for them —
# which is correct behaviour: they have no subscription quota to report.

OAUTH_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
OAUTH_BETA_HEADER = "oauth-2025-04-20"
CREDENTIALS_PATH = Path.home() / ".claude" / ".credentials.json"


def _token_from_credentials_blob(text: str) -> Optional[str]:
    """Extract claudeAiOauth.accessToken from a credentials JSON string."""
    try:
        data = json.loads(text)
        return (data.get("claudeAiOauth") or {}).get("accessToken") or None
    except Exception:
        return None


def _decode_security_value(raw: str) -> Optional[str]:
    """Decode `security -w` output into the stored string value.

    `security -w` prints the raw value, EXCEPT it hex-encodes values that
    contain newlines — and Claude Code stores pretty-printed JSON in the
    Keychain, so default setups hit the hex path. Mirrors the Swift side's
    decodeSecurityValue (Sources/main.swift): try as-is JSON first, then
    hex-decode. NEVER print/log the value — it contains the OAuth token.
    """
    s = raw.strip()
    if not s:
        return None
    # Already valid JSON (minified values without newlines come back verbatim)
    try:
        json.loads(s)
        return s
    except Exception:
        pass
    # Hex-encoded form: even length, all hex digits (optional 0x prefix)
    h = s[2:] if s[:2] in ("0x", "0X") else s
    if len(h) % 2 == 0 and h and all(c in "0123456789abcdefABCDEF" for c in h):
        try:
            return bytes.fromhex(h).decode("utf-8")
        except Exception:
            return None
    return s  # not JSON, not hex — pass through; caller's JSON parse decides


def _read_oauth_token() -> Optional[str]:
    """Return the Claude Code OAuth access token, or None if unavailable.

    Checks, in order: env var, `~/.claude/.credentials.json`, then (on macOS) the
    login Keychain — which is the DEFAULT location Claude Code stores credentials
    on macOS, so Pro/Max users typically have no plaintext file at all.
    """
    env_token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")
    if env_token:
        return env_token
    if CREDENTIALS_PATH.exists():
        try:
            with open(CREDENTIALS_PATH, "r") as f:
                token = _token_from_credentials_blob(f.read())
            if token:
                return token
        except Exception:
            pass
    # macOS Keychain fallback
    if sys.platform == "darwin":
        try:
            import subprocess
            out = subprocess.run(
                ["security", "find-generic-password",
                 "-s", "Claude Code-credentials", "-w"],
                capture_output=True, text=True, timeout=5,
            )
            if out.returncode == 0 and out.stdout.strip():
                blob = _decode_security_value(out.stdout)
                if blob:
                    return _token_from_credentials_blob(blob)
        except Exception:
            pass
    return None


def fetch_oauth_usage() -> Optional[dict]:
    """Call Anthropic's OAuth usage endpoint and return the parsed JSON.

    Returns None (not an error) when no OAuth token is available — this is
    the normal state for Bedrock/Vertex/Console API-key users.
    """
    token = _read_oauth_token()
    if not token:
        return None
    try:
        req = urllib.request.Request(
            OAUTH_USAGE_URL,
            headers={
                "Authorization": f"Bearer {token}",
                "anthropic-beta": OAUTH_BETA_HEADER,
                "Content-Type": "application/json",
                "User-Agent": "local-cc-cost/1.0",
            },
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception:
        return None


def _print_quota_line(quota: Optional[dict]) -> None:
    """Append a one-line subscription-quota summary to text output."""
    if quota is None:
        token_present = _read_oauth_token() is not None
        if token_present:
            print("📊 订阅配额: API 调用失败（网络/token 过期）")
        else:
            print("📊 订阅配额: 未检测到 OAuth token（API-key 用户无订阅限额）")
        return
    five = quota.get("five_hour") or {}
    seven = quota.get("seven_day") or {}
    extra = quota.get("extra_usage") or {}
    msg = f"📊 订阅配额: 5h {five.get('utilization', '?')}% · 7d {seven.get('utilization', '?')}%"
    if extra.get("is_enabled"):
        msg += f" · extra ${extra.get('used_credits', 0):.2f}/${extra.get('monthly_limit', 0):.2f}"
    print(msg)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Analyze Claude Code token usage")
    parser.add_argument("--range", default="week",
                        help="Time range: today, week, month, YYYY-MM-DD, or YYYY-MM-DD:YYYY-MM-DD")
    parser.add_argument("--project", default=None,
                        help="Filter by project keyword")
    parser.add_argument("--by-project", action="store_true",
                        help="Group results by project")
    parser.add_argument("--by-day", action="store_true",
                        help="Group results by day")
    parser.add_argument("--json", action="store_true",
                        help="Output JSON format")
    parser.add_argument("--no-sessions", action="store_true",
                        help="With --json: omit the per-session array from the output "
                             "(totals, daily breakdown and diagnostics are unaffected)")
    parser.add_argument("--include-quota", action="store_true",
                        help="Also fetch Anthropic's OAuth subscription quota (5h + 7d). "
                             "Only works for Pro/Max users who used `claude login`. "
                             "API-key users (Bedrock/Vertex) get no quota info — they have no cap.")
    args = parser.parse_args()

    # Load model pricing (LiteLLM with cache, or fallback)
    load_pricing()

    # Optionally fetch OAuth quota. Done BEFORE scanning so failures are fast.
    subscription_quota = fetch_oauth_usage() if args.include_quota else None

    projects_dir = Path.home() / ".claude" / "projects"
    if not projects_dir.exists():
        print("Error: ~/.claude/projects/ not found. Is Claude Code installed?", file=sys.stderr)
        sys.exit(1)

    start_dt, end_dt = resolve_range(args.range)
    range_label = f"{start_dt.strftime('%Y/%m/%d')} ~ {(end_dt - timedelta(days=1)).strftime('%Y/%m/%d')}"

    sessions = scan_sessions(projects_dir, start_dt, end_dt, args.project)

    if not sessions:
        # Emit a well-formed empty result in JSON mode so callers (e.g. the Swift UI)
        # can parse stdout unconditionally. Prose-only output breaks JSONSerialization.
        if args.json:
            empty = {
                "script_version": __version__,
                "pricing_source": _PRICING_SOURCE,
                "model_pricing": {mc: p for mc, p in MODEL_PRICING.items()},
                "sessions": [],
                "totals_by_model": {},
                "grand_total_cost": 0.0,
                "daily_breakdown": {},
                "diagnostics": scan_diagnostics(),
            }
            if args.no_sessions:
                del empty["sessions"]
            if subscription_quota is not None:
                empty["subscription_quota"] = subscription_quota
            print(json.dumps(empty, indent=2, ensure_ascii=False, default=str))
            sys.exit(0)
        print(f"No sessions found for range: {range_label}")
        if args.project:
            print(f"  (with project filter: {args.project})")
        sys.exit(0)

    if args.json:
        print_json(sessions, subscription_quota=subscription_quota,
                   include_sessions=not args.no_sessions)
    elif args.by_project:
        print_by_project(sessions, range_label)
    elif args.by_day:
        print_by_day(sessions, range_label)
    else:
        print_detail(sessions, range_label)

    if args.include_quota and not args.json:
        _print_quota_line(subscription_quota)


if __name__ == "__main__":
    main()

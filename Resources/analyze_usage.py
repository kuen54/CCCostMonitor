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
    --by-model           Group results by model
    --by-day             Group results by day
    --json               Output JSON instead of table
"""

import json
import sys
import argparse
import urllib.request
import time
from pathlib import Path
from datetime import datetime, timedelta, timezone
from collections import defaultdict
from typing import Optional, Dict, List

# ---------------------------------------------------------------------------
# Model pricing
# ---------------------------------------------------------------------------
LITELLM_PRICING_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
PRICING_CACHE_PATH = Path.home() / ".claude" / "cache" / "litellm_pricing.json"
PRICING_CACHE_TTL = 86400  # 24 hours in seconds

# Fallback pricing (USD per million tokens) when LiteLLM is unavailable.
# Mirrors the latest public Anthropic list prices for Claude 4.x
# (Opus 4.6/4.7, Sonnet 4.6, Haiku 4.5). Keep in sync with class_candidates below.
FALLBACK_PRICING = {
    "opus":   {"input":  5.00, "output": 25.00, "cache_write":  6.25, "cache_read": 0.50},
    "sonnet": {"input":  3.00, "output": 15.00, "cache_write":  3.75, "cache_read": 0.30},
    "haiku":  {"input":  1.00, "output":  5.00, "cache_write":  1.25, "cache_read": 0.10},
}

EMOJI = {"opus": "\U0001f7e3", "sonnet": "\U0001f535", "haiku": "\U0001f7e2"}  # 🟣🔵🟢

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
    "null_msg_id_lines": 0,     # lines without message.id — can't be deduped
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
        # Save to cache
        PRICING_CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(PRICING_CACHE_PATH, "w") as f:
            json.dump(data, f)
        return data
    except Exception:
        # Try reading stale cache as last resort
        if PRICING_CACHE_PATH.exists():
            try:
                with open(PRICING_CACHE_PATH, "r") as f:
                    return json.load(f)
            except Exception:
                pass
        return None


def _per_token_to_per_million(cost_per_token: float) -> float:
    """Convert per-token cost to per-million-tokens cost."""
    return cost_per_token * 1_000_000


def _extract_litellm_entry(entry: dict) -> Optional[dict]:
    """Extract pricing from a LiteLLM entry into our format (per million tokens)."""
    inp = entry.get("input_cost_per_token")
    out = entry.get("output_cost_per_token")
    if inp is None or out is None:
        return None
    cw = entry.get("cache_creation_input_token_cost", inp * 1.25)  # default: 1.25x input
    cr = entry.get("cache_read_input_token_cost", inp * 0.1)       # default: 0.1x input
    return {
        "input":       _per_token_to_per_million(inp),
        "output":      _per_token_to_per_million(out),
        "cache_write": _per_token_to_per_million(cw),
        "cache_read":  _per_token_to_per_million(cr),
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

    # Dynamic representative: scan LiteLLM for `claude-<class>-<major>-<minor>`
    # and pick the newest by (major, minor). Pure-canonical form only
    # (no provider prefixes, no date suffix) to avoid picking regional variants.
    # Minor is capped to 1–2 digits so a date-suffixed legacy key like
    # `claude-opus-4-20250514` (minor=20250514) doesn't outrank `claude-opus-4-7`.
    import re as _re
    pat = _re.compile(r"^claude-(opus|sonnet|haiku)-(\d+)-(\d{1,2})$")
    newest: dict[str, tuple[tuple[int, int], str]] = {}
    for key in raw.keys():
        m = pat.match(key)
        if not m:
            continue
        cls, major, minor = m.group(1), int(m.group(2)), int(m.group(3))
        ver = (major, minor)
        if cls not in newest or ver > newest[cls][0]:
            newest[cls] = (ver, key)

    for cls in ("opus", "sonnet", "haiku"):
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
    """
    if not model_str:
        return ""
    s = model_str.strip()
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
    # 3. Try prefixed canonical variants that LiteLLM commonly uses
    if norm:
        for prefix in ("bedrock/", "vertex_ai/", "anthropic/"):
            key = prefix + norm
            if key in _LITELLM_RAW:
                return _extract_litellm_entry(_LITELLM_RAW[key])
    return None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def classify_model(model_str: str) -> str:
    """Classify a model identifier string into opus/sonnet/haiku."""
    if not model_str:
        return "sonnet"
    m = model_str.lower()
    if "opus" in m:
        return "opus"
    if "haiku" in m:
        return "haiku"
    return "sonnet"


def parse_iso_ts(ts_str) -> Optional[datetime]:
    """Parse an ISO-8601 timestamp string to a timezone-aware datetime."""
    if not ts_str or not isinstance(ts_str, str):
        return None
    try:
        return datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
    except Exception:
        return None


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
    return (
        usage["input_tokens"]  * p["input"]       / 1_000_000
      + usage["output_tokens"] * p["output"]      / 1_000_000
      + usage["cache_write"]   * p["cache_write"] / 1_000_000
      + usage["cache_read"]    * p["cache_read"]  / 1_000_000
    )


def cost_for_usage(usage: dict, model_class: str) -> float:
    """Backwards-compat helper: compute cost from class-level representative pricing.

    Only used for legacy paths that don't have a per-message model_str. New code
    should accumulate `usage["cost"]` during scan via cost_for_message.
    """
    p = MODEL_PRICING.get(model_class, MODEL_PRICING.get("sonnet", FALLBACK_PRICING["sonnet"]))
    return (
        usage["input_tokens"]  * p["input"]       / 1_000_000
      + usage["output_tokens"] * p["output"]      / 1_000_000
      + usage["cache_write"]   * p["cache_write"] / 1_000_000
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
    return f"🔬 扫描自检: 原始行={d['raw_usage_lines']}  去重后={d['unique_messages']}  inflation={f}x{nulls}{flag}"


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
        return datetime.fromisoformat(parts[0]), datetime.fromisoformat(parts[1]) + timedelta(days=1)
    # Single date
    d = datetime.fromisoformat(spec)
    return d, d + timedelta(days=1)


# ---------------------------------------------------------------------------
# Core analysis
# ---------------------------------------------------------------------------
def scan_sessions(projects_dir: Path, start_dt: datetime, end_dt: datetime, project_filter: Optional[str]):
    """Scan all JSONL files and return structured session data."""
    start_epoch = start_dt.timestamp()

    # Reset diagnostic counters for this scan
    _SCAN_STATS["raw_usage_lines"] = 0
    _SCAN_STATS["unique_messages"] = 0
    _SCAN_STATS["null_msg_id_lines"] = 0

    # Convert local-time range boundaries to UTC for comparing with message timestamps
    _local_tz = datetime.now().astimezone().tzinfo
    start_utc = start_dt.replace(tzinfo=_local_tz).astimezone(timezone.utc)
    end_utc = end_dt.replace(tzinfo=_local_tz).astimezone(timezone.utc)

    # Collect JSONL files that might contain in-range messages.
    # Only skip files last modified BEFORE the range start.
    # Do NOT skip files modified after the range end — cross-day sessions
    # may have mtime beyond the range but still contain in-range messages.
    all_files: list[dict] = []
    for p in projects_dir.rglob("*.jsonl"):
        mtime = p.stat().st_mtime
        if mtime < start_epoch:
            continue
        is_sub = "subagents" in str(p)
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
    seen_msg_ids: set[str] = set()
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

        try:
            with open(finfo["path"], "r") as f:
                for line in f:
                    try:
                        data = json.loads(line)
                    except json.JSONDecodeError:
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
                        usage_raw = m.get("usage", {})
                        inp = usage_raw.get("input_tokens", 0)
                        out = usage_raw.get("output_tokens", 0)
                        if not inp and not out:
                            continue
                        # Filter: only count messages whose timestamp falls within the requested range
                        if ts and (ts < start_utc or ts >= end_utc):
                            continue
                        _SCAN_STATS["raw_usage_lines"] += 1
                        # Dedup by message.id (see comment at top of this function)
                        msg_id = m.get("id")
                        if msg_id:
                            if msg_id in seen_msg_ids:
                                continue
                            seen_msg_ids.add(msg_id)
                        else:
                            _SCAN_STATS["null_msg_id_lines"] += 1
                        _SCAN_STATS["unique_messages"] += 1
                        model_str = m.get("model", "") or ""
                        model_cls = classify_model(model_str)
                        cw = usage_raw.get("cache_creation_input_tokens", 0)
                        cr = usage_raw.get("cache_read_input_tokens", 0)
                        # Per-message cost using the exact model string (preferred over
                        # class-level pricing — avoids mis-pricing Opus 4.7 as Opus 4).
                        single = {"input_tokens": inp, "output_tokens": out, "cache_write": cw, "cache_read": cr}
                        msg_cost = cost_for_message(single, model_str)
                        # Session-level aggregation
                        mu = sessions[sid]["models"][model_cls]
                        mu["messages"] += 1
                        mu["input_tokens"] += inp
                        mu["output_tokens"] += out
                        mu["cache_write"] += cw
                        mu["cache_read"] += cr
                        mu["cost"] += msg_cost
                        # Per-day aggregation (using message's own local date)
                        if ts:
                            day_key = ts.astimezone(_local_tz).strftime("%Y-%m-%d")
                        else:
                            day_key = sessions[sid]["first_ts"].strftime("%Y-%m-%d") if sessions[sid]["first_ts"] else "unknown"
                        dmu = sessions[sid]["daily_models"][day_key][model_cls]
                        dmu["messages"] += 1
                        dmu["input_tokens"] += inp
                        dmu["output_tokens"] += out
                        dmu["cache_write"] += cw
                        dmu["cache_read"] += cr
                        dmu["cost"] += msg_cost
        except Exception:
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
    grand_cost = 0.0

    for sid, sdata in sorted_sessions:
        session_cost = sum(u["cost"] for u in sdata["models"].values())
        grand_cost += session_cost
        date_str = sdata["first_ts"].strftime("%m/%d %H:%M") if sdata["first_ts"] else "N/A"
        first_msg = sdata["first_msg"] or "-"

        print(f"\n\U0001f539 {date_str}  {sdata['project']}/{sid[:8]}  \U0001f4b0${session_cost:.2f}")
        print(f"   \u300c{first_msg}\u300d")

        for mc in ("opus", "sonnet", "haiku"):
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
    for mc in ("opus", "sonnet", "haiku"):
        if mc not in grand_by_model:
            continue
        mu = grand_by_model[mc]
        c = mu["cost"]
        total_cost += c
        p = MODEL_PRICING[mc]
        all_in = mu["input_tokens"] + mu["cache_write"] + mu["cache_read"]
        total_tokens += all_in + mu["output_tokens"]
        print(f"""
{EMOJI[mc]} {mc.upper()}  (Input ${p['input']}/M, Output ${p['output']}/M, CacheW ${p['cache_write']}/M, CacheR ${p['cache_read']}/M)
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
        for mc in ("opus", "sonnet", "haiku"):
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
        for mc in ("opus", "sonnet", "haiku"):
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


def print_json(sessions: dict, subscription_quota: Optional[dict] = None):
    """Output structured JSON."""
    result = {
        "pricing_source": _PRICING_SOURCE,
        "model_pricing": {mc: p for mc, p in MODEL_PRICING.items()},
        "sessions": [],
        "totals_by_model": {},
        "grand_total_cost": 0.0,
    }
    grand_by_model: dict[str, dict] = defaultdict(empty_usage)

    for sid, sdata in sessions.items():
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


def _read_oauth_token() -> Optional[str]:
    """Return the Claude Code OAuth access token, or None if unavailable."""
    env_token = __import__("os").environ.get("CLAUDE_CODE_OAUTH_TOKEN")
    if env_token:
        return env_token
    if not CREDENTIALS_PATH.exists():
        return None
    try:
        with open(CREDENTIALS_PATH, "r") as f:
            data = json.load(f)
        return (data.get("claudeAiOauth") or {}).get("accessToken") or None
    except Exception:
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
    parser.add_argument("--by-model", action="store_true",
                        help="Group results by model (default detail view already shows this)")
    parser.add_argument("--by-day", action="store_true",
                        help="Group results by day")
    parser.add_argument("--json", action="store_true",
                        help="Output JSON format")
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
                "pricing_source": _PRICING_SOURCE,
                "model_pricing": {mc: p for mc, p in MODEL_PRICING.items()},
                "sessions": [],
                "totals_by_model": {},
                "grand_total_cost": 0.0,
                "daily_breakdown": {},
                "diagnostics": scan_diagnostics(),
            }
            if subscription_quota is not None:
                empty["subscription_quota"] = subscription_quota
            print(json.dumps(empty, indent=2, ensure_ascii=False, default=str))
            sys.exit(0)
        print(f"No sessions found for range: {range_label}")
        if args.project:
            print(f"  (with project filter: {args.project})")
        sys.exit(0)

    if args.json:
        print_json(sessions, subscription_quota=subscription_quota)
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

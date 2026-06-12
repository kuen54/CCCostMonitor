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
    --no-cache           Bypass the incremental scan cache (read AND write)
    --gap-minutes N      Active-time sessionization gap (default 10); events closer
                         than N minutes merge into one active interval
    --time-year YYYY     Emit per-day active-time totals for a whole year (JSON only)
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

__version__ = "1.5.1"

# ---------------------------------------------------------------------------
# Active-time tracking
# ---------------------------------------------------------------------------
# "Active time" = gap-merged event intervals, where an event is the top-level
# timestamp of ANY JSONL line (user/assistant/system/attachment/...), not just
# assistant lines. Events closer than the gap merge into one interval.
DEFAULT_GAP_MINUTES = 10
# Set once in main() (from --gap-minutes) BEFORE any cache load or scan; the
# cache stamps this value and a mismatch degrades to a silent full rescan.
_GAP_MINUTES = DEFAULT_GAP_MINUTES
# Accepted event epoch range: [1970-01-01, 9999-01-01) UTC. Events outside are
# rejected at extraction (hostile/garbage timestamps), so every cached pair is
# fromtimestamp()+astimezone()-safe at query time. The extractor and
# _valid_cache_entry MUST agree on these bounds — otherwise the script could
# write a cache entry its own validator rejects, silently forcing a full
# rescan on every run.
_TIME_EPOCH_MIN = 0
_TIME_EPOCH_MAX = 253370764800  # 9999-01-01T00:00:00Z


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
    # prefiltered_lines — non-assistant lines skipped before json.loads
    # (substring prefilter). DEFINITION CHANGE with the incremental cache
    # (1.5.0 cache batch): the prefilter gate is now per-FILE (armed by the
    # file's own first_msg/first_ts, compared against the file-local min ts)
    # instead of per-session-shared-across-files. Required so cached per-file
    # counts are deterministic (independent of sibling-file scan order). The
    # per-file gate arms later and against a higher threshold, so the count
    # is slightly LOWER than pre-cache builds (~0.1–0.3% on the real corpus).
    # Informational only: the prefilter is conservative, so tokens, costs,
    # sessions, daily buckets and every other counter are bit-identical.
    "prefiltered_lines": 0,
    "cache_hit_files": 0,       # files served from the incremental scan cache (no re-parse)
    "cache_miss_files": 0,      # files parsed this run (cache absent/stale); 0 when cache bypassed
    "cache_pruned_files": 0,    # cache entries dropped because their file disappeared
    "time_event_lines": 0,      # raw lines whose timestamp extraction succeeded (active-time
                                # events; range-independent scalar, all line types)
}

# ---------------------------------------------------------------------------
# Incremental per-file scan cache
# ---------------------------------------------------------------------------
# Each entry describes the WHOLE file (range-agnostic): per-(local day, exact
# model string) sums of FINAL per-message usage (after streaming max/delta
# upgrades) plus day-bucketed diagnostic counters. Range filtering happens at
# merge time by comparing day-key strings — exact for midnight-aligned ranges
# (lexicographic order on %Y-%m-%d equals date order, and both range bounds
# are local midnights). Costs are NOT stored: they are recomputed per bucket
# at query time, which equals the per-message sum because per-message
# cw >= cw_1h always holds (cw = max(top, cw_5m+cw_1h)), making the pricing
# formula linear over a bucket that shares one model_str.
# The OAuth token NEVER touches this file: entries hold only usage aggregates
# and the first-50-chars first_msg snippet.
#
# Equivalence contract vs pre-cache builds: every data field (tokens, costs,
# sessions, daily_breakdown, totals) and every diagnostics counter is exactly
# preserved, with TWO documented exceptions:
#   1. prefiltered_lines — gating became per-file (see its comment in
#      _SCAN_STATS); informational only, never affects data fields.
#   2. Cross-midnight streamed messages at a range boundary — a message whose
#      streamed lines straddle a local midnight that coincides with the query
#      range edge. This build attributes the WHOLE message (with all streaming
#      max/delta upgrades applied) to its FIRST line's local day; pre-cache
#      builds instant-filtered each line BEFORE dedup, so a day1-only query
#      saw only the partial first-line usage while a day2-only query counted
#      the message again in full — the two adjacent single-day queries
#      double-counted (their sum exceeded the true total). This build
#      conserves: the message appears exactly once, under its first day.
#      Zero such messages exist in the real corpus today (0 of 23,650 span
#      more than one local day); divergence is theoretical and only at exact
#      midnight-boundary range cuts.
# Cold, warm and --no-cache runs of THIS script are always mutually identical
# (modulo the additive cache_hit/miss/pruned counters); --no-cache is the
# always-available ground truth for verifying the cache.
SCAN_CACHE_PATH = Path.home() / ".claude" / "cache" / "cc-monitor" / "scan-cache.json"
# v2: entries gain active-time interval lists ("time": absolute UTC epoch
# second triples [start, end, counts], gap-merged per file at _GAP_MINUTES —
# NOT split into local days, so the DST fall-back fold stays disambiguated;
# counts = per-model-class tallies of the assistant model-tagged events
# inside the interval; see parse_file's entry-shape docstring) +
# "time_event_lines"; cache header gains "gap_minutes" (a mismatch at load
# time → silent full rescan, same degrade path as a format/script-version
# mismatch). All v1 caches silently rebuild once. v2 never shipped, so its
# earlier development shapes (day-keyed; 2-element [start, end] pairs) exist
# at most on dev machines — the validator rejects both, degrading to one
# silent full rescan.
SCAN_CACHE_FORMAT_VERSION = 2

# Whether the current scan actually used the cache (False under --no-cache or
# a non-midnight-aligned range). Drives diagnostics_line() segment suppression.
_CACHE_ACTIVE = False


def _tz_stamp() -> list:
    """Static system-timezone fingerprint stamped into the cache header.

    Cached day keys are baked with the zone active at parse time; a zone
    change makes them stale vs a fresh cold scan, so the whole cache is
    discarded on mismatch. Deliberately composed of *static* zone properties:
    a DST flip inside one zone does NOT invalidate (day keys for past instants
    are per-datetime astimezone results, unaffected by the current DST state).
    """
    return [time.tzname[0], time.tzname[1], time.timezone, time.altzone, time.daylight]


def _valid_cache_entry(e) -> bool:
    """Strict structural validation of one cache entry (never partial use)."""
    try:
        if not isinstance(e, dict):
            return False
        if not isinstance(e.get("mtime_ns"), int) or not isinstance(e.get("size"), int):
            return False
        for k in ("peek_ts", "first_ts"):
            v = e.get(k)
            if v is not None and not isinstance(v, str):
                return False
        if not isinstance(e.get("first_msg"), str):
            return False
        for aggk in ("agg", "agg_no_ts"):
            agg = e.get(aggk)
            if not isinstance(agg, dict):
                return False
            for day, models in agg.items():
                if not isinstance(day, str) or not isinstance(models, dict):
                    return False
                for ms, sums in models.items():
                    if not isinstance(ms, str):
                        return False
                    if not (isinstance(sums, list) and len(sums) == 6
                            and all(isinstance(x, int) for x in sums)):
                        return False
        cbd = e.get("counters_by_day")
        if not isinstance(cbd, dict):
            return False
        for day, c in list(cbd.items()) + [("", e.get("counters_no_ts"))]:
            if not isinstance(day, str):
                return False
            if not (isinstance(c, list) and len(c) == 4 and all(isinstance(x, int) for x in c)):
                return False
        for k in ("skipped_lines", "prefiltered_lines", "null_ts_lines", "time_event_lines"):
            if not isinstance(e.get(k), int):
                return False
        # Active-time intervals: [[start_epoch, end_epoch, counts], ...] —
        # int UTC epoch seconds, s <= e, within the same bounds the extractor
        # enforces (so a self-written entry ALWAYS revalidates — a stricter
        # check here would silently force a full rescan on every run) and
        # fromtimestamp()/astimezone()-safe at query time. counts is a
        # possibly-empty {model_class: positive int} dict — parse_file only
        # ever increments, so 0 never appears in a self-written entry.
        # Anything else (forged floats, reversed pairs, out-of-range epochs,
        # unknown class keys, the earlier v2 dev shapes: day-keyed or
        # 2-element pairs) → silent full rescan.
        tm = e.get("time")
        if not isinstance(tm, list):
            return False
        for iv in tm:
            if not (isinstance(iv, list) and len(iv) == 3
                    and isinstance(iv[0], int) and isinstance(iv[1], int)
                    and _TIME_EPOCH_MIN <= iv[0] <= iv[1] < _TIME_EPOCH_MAX
                    and isinstance(iv[2], dict)):
                return False
            for cls, n in iv[2].items():
                if cls not in MODEL_CLASSES or not isinstance(n, int) or n < 1:
                    return False
        return True
    except Exception:
        return False


def _load_scan_cache() -> dict:
    """Load the per-file scan cache; ANY anomaly degrades to an empty cache.

    Missing file, corrupt JSON, wrong types, format/script-version mismatch,
    or timezone change all silently return {} → full rescan. Cache problems
    must never crash or skew results.
    """
    try:
        with open(SCAN_CACHE_PATH, "r") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return {}
        if data.get("format_version") != SCAN_CACHE_FORMAT_VERSION:
            return {}
        if data.get("script_version") != __version__:
            return {}
        if data.get("tz") != _tz_stamp():
            return {}
        # Cached intervals were gap-merged with the gap active at parse time;
        # a different gap can't be reconstructed from merged intervals →
        # silent full rescan, same as a format-version mismatch.
        if data.get("gap_minutes") != _GAP_MINUTES:
            return {}
        files = data.get("files")
        if not isinstance(files, dict):
            return {}
        for path, entry in files.items():
            if not isinstance(path, str) or not _valid_cache_entry(entry):
                return {}
        return files
    except Exception:
        return {}


def _write_scan_cache(files: dict) -> None:
    """Atomic write (tmp in same dir + os.replace); failures are best-effort."""
    tmp_path = None
    try:
        SCAN_CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = SCAN_CACHE_PATH.with_name(SCAN_CACHE_PATH.name + f".tmp{os.getpid()}")
        doc = {
            "format_version": SCAN_CACHE_FORMAT_VERSION,
            "script_version": __version__,
            "tz": _tz_stamp(),
            "gap_minutes": _GAP_MINUTES,
            "files": files,
        }
        with open(tmp_path, "w") as f:
            json.dump(doc, f)
        os.replace(tmp_path, SCAN_CACHE_PATH)
    except Exception:
        if tmp_path is not None:
            try:
                tmp_path.unlink(missing_ok=True)
            except Exception:
                pass


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


def _extract_line_ts(line: str) -> Optional[int]:
    """Per-line timestamp extraction for active-time events (top-level key only).

    Returns the event as an int UTC epoch second — the ABSOLUTE domain every
    merge stage works in (per-file and query-time), immune to DST fold/gap
    ambiguity; localization happens only at the final day-split.

    Full json.loads per raw line. A substring heuristic (first '"timestamp":"'
    occurrence, strictly format-validated) was measured against the full parse
    on the real corpus: 3.13% of lines mismatched (3543/113226) — every one a
    `file-history-snapshot` line whose only "timestamp" key is NESTED (no
    top-level key; the nested snapshot time can be stale, so it must not
    become an activity event). Far above the 0.1% acceptance threshold, so the
    heuristic was rejected per the design contract in favor of the full parse
    (measured cold --no-cache month-scan cost on the real corpus, interleaved
    runs: ~1.5s → ~2.4s; warm runs unaffected — extraction only runs on
    cache-miss files, and the app's steady state is warm).
    Offset-less (naive) timestamps are rejected: events must stay mutually
    comparable and astimezone()-correct. Independent of the usage path — the
    assistant-line prefilter below is untouched and never sees this result.
    """
    try:
        data = json.loads(line)
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    dt = parse_iso_ts(data.get("timestamp"))
    if dt is None or dt.tzinfo is None:
        return None
    # Truncate to whole seconds: storage is int epoch seconds, so EVERY merge
    # stage (per-file and query-time) must see identical second precision —
    # mixed precision breaks the per-file ≡ query-time merge equivalence for
    # gaps within 1s of the threshold (observed on the real corpus: ~600.5s
    # heartbeat gaps merged after truncation but not before).
    ep = int(dt.replace(microsecond=0).timestamp())
    if not (_TIME_EPOCH_MIN <= ep < _TIME_EPOCH_MAX):
        return None
    return ep


def _gap_merge(pairs_sorted: list, gap) -> list:
    """Merge sorted (start, end) pairs whose gap is <= `gap`.

    Domain-agnostic: works on int epoch seconds with an int gap (the only
    domain both merge stages use today) or on datetimes with a timedelta.
    Inclusive condition (next_start - prev_end <= gap), applied identically
    per-file and at query time — both in the ABSOLUTE epoch domain — so the
    two-stage merge equals a single global gap-merge of the event set (every
    stored interval endpoint is a real event). Merging in the absolute domain
    is what keeps DST fall-back days correct: local wall-clock seconds are
    non-monotonic in real time there (the 01:00–02:00 hour repeats), so a
    wall-clock-domain merge fabricates/loses gaps around the fold.
    """
    merged: list = []
    for a, b in pairs_sorted:
        if merged and a - merged[-1][1] <= gap:
            if b > merged[-1][1]:
                merged[-1][1] = b
        else:
            merged.append([a, b])
    return [(a, b) for a, b in merged]


def _dominant_model(counts: dict) -> Optional[str]:
    """Dominant model class of one interval's model-tagged event counts.

    Highest count wins; ties break by the fixed MODEL_CLASSES order
    (fable > opus > sonnet > haiku > other). Empty counts (interval held no
    model-tagged assistant events — e.g. user/system lines only) → None.
    Keys are guaranteed members of MODEL_CLASSES: classify_model only emits
    those, and _valid_cache_entry rejects anything else.
    """
    if not counts:
        return None
    return max(counts.items(),
               key=lambda kv: (kv[1], -MODEL_CLASSES.index(kv[0])))[0]


def _first_offset_change(lo: datetime, hi: datetime) -> datetime:
    """First instant in (lo, hi] whose local UTC offset differs from lo's.

    Precondition: offset(lo) != offset(hi) and the span holds at most one
    transition (callers pass spans <= one local day; real zones transition at
    most once per day). Bisection on whole epoch seconds (~17 probes/day).
    """
    off = lo.astimezone().utcoffset()
    lo_e, hi_e = int(lo.timestamp()), int(hi.timestamp())
    while hi_e - lo_e > 1:
        mid = (lo_e + hi_e) // 2
        if datetime.fromtimestamp(mid, timezone.utc).astimezone().utcoffset() == off:
            lo_e = mid
        else:
            hi_e = mid
    return datetime.fromtimestamp(hi_e, timezone.utc)


def _wall_sec(t: datetime, off: timedelta, day) -> int:
    """Wall-clock second-of-`day` of aware instant t under fixed UTC offset off.

    Clamped to [0, 86400] — the clamp only engages in pathological zones whose
    DST transition crosses local midnight (the wall projection then leaves the
    day); invariants stay intact there at the cost of edge-second precision.
    """
    wall = t.astimezone(timezone.utc).replace(tzinfo=None) + off
    delta = (wall - datetime(day.year, day.month, day.day)).total_seconds()
    return int(min(max(delta, 0), 86400))


def _split_interval_by_local_day(a: datetime, b: datetime) -> list:
    """Split aware interval [a, b] at local midnights AND at DST transitions
    into (day_key, start_sec, end_sec) wall-clock pieces, 0 <= s <= e <= 86400
    (86400 = next midnight). Within each piece the UTC offset is constant, so
    the absolute→wall mapping is monotonic and s <= e holds structurally —
    including on fall-back days, where the repeated 01:00–02:00 hour would
    otherwise produce s > e (negative durations).

    Wall-clock semantics on transition days (documented design choice — the
    0–24h week axis renders wall-clock positions and totals equal the summed
    piece lengths):
      * Spring forward: a session bridging the gap is split around the
        nonexistent hour ([01:50, 02:00] + [03:00, 03:05]); its total equals
        real elapsed time (the skipped hour is no longer counted as active).
      * Fall back: a session bridging the fold is split at it ([01:59, 02:00]
        + [01:00, 01:05]); each wall position counts once, so a session
        spanning the whole repeated hour shows up to 1h LESS than elapsed
        (the per-day union in _build_time_days collapses the overlap).
    Day attribution and midnights are derived per-instant via astimezone()
    (aware conversions are unambiguous — no naive-fold guessing). An interval
    ending exactly at local midnight yields no zero-width next-day piece (the
    previous day's …→86400 piece carries the endpoint); a true zero-duration
    interval (a == b) is kept truthful as one (s, s) piece.
    """
    pieces = []
    cur = a
    while True:
        day = cur.astimezone().date()
        day_key = day.strftime("%Y-%m-%d")
        # Absolute instant of the next local midnight (naive→aware attach is
        # fine here: midnights are virtually never inside a fold; the guard
        # below keeps pathological zones from stalling the walk).
        next_mid = (datetime(day.year, day.month, day.day) + timedelta(days=1)).astimezone()
        if next_mid <= cur:
            next_mid = cur + timedelta(days=1)
        seg_end = min(b, next_mid)
        # Sub-split [cur, seg_end] at the (at most one) DST transition inside.
        sub = cur
        while True:
            off = sub.astimezone().utcoffset()
            if seg_end.astimezone().utcoffset() == off:
                nxt = seg_end
            else:
                nxt = _first_offset_change(sub, seg_end)
            s = _wall_sec(sub, off, day)
            e = _wall_sec(nxt, off, day)
            pieces.append((day_key, s, e))
            if nxt >= seg_end:
                break
            sub = nxt
        if seg_end >= b:
            break
        cur = seg_end
    return pieces


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
    Offset-less (naive) timestamps are skipped, not compared: current_min is
    always aware (parse_file never tracks naive values), and a naive/aware
    `<` raises TypeError — one such hostile line must not kill the whole
    scan. Consistent with the full-parse path, which ignores naive
    timestamps for first_ts too.
    """
    for key in ('"timestamp":"', '"timestamp": "'):
        start = line.find(key)
        while start != -1:
            vstart = start + len(key)
            vend = line.find('"', vstart)
            if vend == -1:
                return True  # truncated/odd line — let the full parser judge
            ts = parse_iso_ts(line[vstart:vend])
            if ts is not None and ts.tzinfo is not None and ts < current_min:
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
        "cache_hit_files": _SCAN_STATS["cache_hit_files"],
        "cache_miss_files": _SCAN_STATS["cache_miss_files"],
        "cache_pruned_files": _SCAN_STATS["cache_pruned_files"],
        "time_event_lines": _SCAN_STATS["time_event_lines"],
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
    cache_seg = (f"  cache=hit:{d['cache_hit_files']}/miss:{d['cache_miss_files']}"
                 f"/pruned:{d['cache_pruned_files']}") if _CACHE_ACTIVE else ""
    return f"🔬 扫描自检: 原始行={d['raw_usage_lines']}  去重后={d['unique_messages']}  inflation={f}x{nulls}{upgraded}{skipped}{failed}{null_ts}{prefiltered}{cache_seg}{flag}"


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
    """Parse one --range date bound; exit(2) with a clear error on bad input.

    Bounds must be plain local dates (= local midnight), matching the
    documented grammar (YYYY-MM-DD). datetime.fromisoformat would also accept
    sub-day forms that survive the ':' split (e.g. '2026-06-10T12') or an
    explicit UTC offset ('2026-06-10+08:00'); those are rejected explicitly:
    range filtering is day-granular (local day keys), so a sub-day or
    offset-shifted bound cannot be honored exactly — an explicit exit(2)
    instead of silently wrong numbers.
    """
    try:
        d = datetime.fromisoformat(s)
    except ValueError:
        print(f"Error: invalid --range date '{s}' (expected today, week, month, "
              f"YYYY-MM-DD, or YYYY-MM-DD:YYYY-MM-DD)", file=sys.stderr)
        sys.exit(2)
    if d.tzinfo is not None or d.time() != datetime.min.time():
        print(f"Error: --range date '{s}' must be a plain date (YYYY-MM-DD), "
              f"without a time component or UTC offset", file=sys.stderr)
        sys.exit(2)
    return d


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
def parse_file(path: Path, is_sub: bool):
    """Parse one whole JSONL file into a range-agnostic cache entry.

    Returns (entry, ok). ok=False means an OSError interrupted the read
    (open failure or mid-file I/O error); the partial entry is still merged
    (matching the pre-cache behavior, where lines counted before the error
    stayed counted) but must NOT be stored in the cache.

    Single parse path for cold AND warm runs: both flows go entry → merge,
    so cache equivalence is structural, not coincidental. NO range filtering
    here — that happens at merge time via day-key comparison.

    Dedup is PER FILE (`seen` local). Assumption (empirically verified:
    0 collisions across 23k+ message.ids on the real corpus): a message.id
    (or `req:<requestId>`) never repeats across files. If session
    resume/copy ever breaks this, cross-file duplicates inflate
    raw_usage_lines AND unique_messages together — detection: a sudden
    unique_messages jump vs subscription-quota reality, or warm-vs-cold
    drift caught by rerunning with --no-cache (always-available ground
    truth).

    Entry shape (JSON-serializable):
      peek_ts:    ISO ts of the first physical line (None if unparseable) —
                  replaces the upper-prune peek for cached files.
      first_msg:  first user message snippet (main files only; "" otherwise).
      first_ts:   ISO of the min top-level timestamp across all lines.
      agg:        {day_key: {model_str: [inp, out, cw, cw_1h, cr, msgs]}} —
                  FINAL per-message usage after streaming max/delta upgrades.
      agg_no_ts:  same shape, for usage lines with no parseable timestamp,
                  keyed by the file-local fallback day (always merged,
                  regardless of range — matching the cold range-filter bypass).
      counters_by_day / counters_no_ts: [raw, unique, null_id, upgraded] —
                  the four range-dependent diagnostic counters, bucketed by
                  each counted line's local day.
      skipped_lines / prefiltered_lines / null_ts_lines: plain scalars
                  (incremented before/independent of the range check).
      time:       [[start_epoch, end_epoch, counts], ...] — active-time
                  intervals from ALL line types' timestamps (int UTC epoch
                  seconds), gap-merged at _GAP_MINUTES per file, sorted,
                  disjoint. counts = {model_class: positive int}, possibly
                  empty — tallies of the model-tagged events (assistant
                  lines with a timestamp AND a model string) inside the
                  interval; query time sums them across merging files and
                  picks the dominant class per merged interval.
                  Deliberately ABSOLUTE and NOT split into local days: the
                  cache must disambiguate the DST fall-back fold (two real
                  instants share one wall-clock second), which
                  seconds-of-local-day pairs cannot. Localization (midnight +
                  DST-transition split) and range filtering happen at query
                  time in _build_time_days.
      time_event_lines: count of lines whose timestamp extraction succeeded
                  (range-independent scalar).
    """
    entry = {
        "peek_ts": None,
        "first_msg": "",
        "first_ts": None,
        "agg": {},
        "agg_no_ts": {},
        "counters_by_day": {},
        "counters_no_ts": [0, 0, 0, 0],
        "skipped_lines": 0,
        "prefiltered_lines": 0,
        "null_ts_lines": 0,
        "time": [],
        "time_event_lines": 0,
    }
    # Active-time event epochs (every line type), gap-merged after the loop.
    events: list = []
    # (epoch, model_class) for assistant lines carrying a model string —
    # a subset of `events` (same epochs), tallied per interval after the merge.
    model_events: list = []
    # Per-file dedup: Anthropic message.id is unique per API call, but Claude
    # Code writes one JSONL line per content block (thinking / text / tool_use…),
    # each carrying the same `message.usage`. Without dedup, a response with N
    # blocks is counted N times — inflating tokens and cost by ~1.5–3x.
    # The usage is NOT identical across those lines though: output_tokens grows
    # with streaming progress (first line often 1, last line the real value), so
    # each id keeps its counted usage + the sums list it landed in, letting
    # later lines back-fill the delta.
    seen: dict[str, dict] = {}
    first_ts_dt: Optional[datetime] = None
    line_no = 0
    ok = True
    # File-level fallback is deliberately narrow (I/O errors only): one malformed
    # *line* must not discard the rest of the file's usage. Per-line problems are
    # counted in skipped_lines and the file keeps scanning.
    # errors="replace": invalid UTF-8 bytes become U+FFFD instead of raising
    # UnicodeDecodeError mid-iteration (which would escape the per-line handler
    # and crash the whole scan); the mangled line then fails json.loads and is
    # counted in skipped_lines while the rest of the file survives.
    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                line_no += 1
                if not line.strip():
                    continue
                # Active-time event: lightweight timestamp extraction on EVERY
                # raw line (single code path for assistant and non-assistant
                # lines — cold == warm by construction). Independent of the
                # usage prefilter/first_ts logic below; never feeds into them.
                ts_ev = _extract_line_ts(line)
                if ts_ev is not None:
                    events.append(ts_ev)
                    entry["time_event_lines"] += 1
                # Assistant-line prefilter: ~57% of lines (74% of bytes) are
                # non-assistant, and the only things non-assistant lines
                # contribute are file metadata: first_msg (user lines,
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
                # State is per-FILE (not per-session): required for cache
                # independence — a cached count must not depend on sibling-file
                # scan order. Only prefiltered_lines can differ vs the old
                # session-shared gate; tokens/costs/counts are unaffected
                # (assistant lines are never prefiltered).
                # Invariant: Claude Code writes compact JSON where
                # '"type":"assistant"' appears verbatim in assistant lines;
                # the spaced variant covers a non-compact encoder. If the
                # format ever drifts so assistant lines fail this substring
                # test, raw_usage_lines/unique_messages collapse toward 0
                # and inflation_factor toward None — visible in diagnostics —
                # while prefiltered_lines (counted here) shows the skip
                # volume.
                if ((is_sub or entry["first_msg"])
                        and first_ts_dt is not None
                        and '"type":"assistant"' not in line
                        and '"type": "assistant"' not in line
                        and not _line_may_lower_first_ts(line, first_ts_dt)):
                    entry["prefiltered_lines"] += 1
                    continue
                try:
                    data = json.loads(line)
                    if not isinstance(data, dict):
                        entry["skipped_lines"] += 1
                        continue

                    # First physical line's top-level timestamp — stands in for
                    # the upper-prune peek on cache hits (validators guarantee
                    # the file is unchanged since parse time). Mirrors the peek
                    # semantics: blank/malformed/non-dict first line → None.
                    if line_no == 1:
                        _pts = parse_iso_ts(data.get("timestamp"))
                        entry["peek_ts"] = _pts.isoformat() if _pts else None

                    # Capture first user message (main session files only)
                    if not is_sub and not entry["first_msg"]:
                        if data.get("type") == "user" and "message" in data:
                            msg = data["message"]
                            if isinstance(msg, dict):
                                content = msg.get("content", "")
                                if isinstance(content, list):
                                    for part in content:
                                        if isinstance(part, dict) and part.get("type") == "text":
                                            entry["first_msg"] = part.get("text", "")[:50]
                                            break
                                elif isinstance(content, str):
                                    entry["first_msg"] = content[:50]
                            elif isinstance(msg, str):
                                entry["first_msg"] = msg[:50]

                    # Timestamp (running min over all lines of THIS file).
                    # Naive (offset-less) timestamps are ignored: first_ts_dt
                    # must stay uniformly aware — a naive/aware `<` raises
                    # TypeError, and one hostile line must not kill the scan
                    # (here or in _line_may_lower_first_ts, which compares
                    # against this value).
                    ts = parse_iso_ts(data.get("timestamp"))
                    if (ts and ts.tzinfo is not None
                            and (first_ts_dt is None or ts < first_ts_dt)):
                        first_ts_dt = ts

                    # Usage from assistant messages
                    if data.get("type") == "assistant" and "message" in data:
                        m = data["message"]
                        if not isinstance(m, dict):
                            entry["skipped_lines"] += 1
                            continue
                        # Model-tagged active-time event: ts_ev is the exact
                        # epoch _extract_line_ts already recorded for this
                        # line, so the tag lands inside the interval that
                        # event built. Only assistant lines reach here — the
                        # prefilter and non-assistant parsing are untouched.
                        # Streamed repeat lines tag too (pre-dedup): per-line
                        # weight is what "dominant inside an interval" wants.
                        # Lines without a model string stay untagged (no
                        # classify_model default-to-sonnet guessing here).
                        # "<synthetic>" is a Claude Code placeholder on locally
                        # fabricated lines (API error/interrupt, zero usage —
                        # no model streamed); classify_model would bucket it
                        # sonnet, so angle-bracket placeholders stay untagged.
                        if ts_ev is not None:
                            _mstr = m.get("model")
                            if (isinstance(_mstr, str) and _mstr
                                    and not _mstr.startswith("<")):
                                model_events.append((ts_ev, classify_model(_mstr)))
                        usage_raw = m.get("usage") or {}
                        if not isinstance(usage_raw, dict):
                            entry["skipped_lines"] += 1
                            continue
                        inp = int(usage_raw.get("input_tokens") or 0)
                        out = int(usage_raw.get("output_tokens") or 0)
                        if not inp and not out:
                            continue
                        # Day bucket from the message's own local date
                        # (astimezone() resolves the local zone per datetime →
                        # DST-safe). No-ts lines go to the always-merged
                        # fallback bucket (they bypass the range filter).
                        # A streamed message crossing local midnight buckets
                        # wholly under its FIRST line's day (sanctioned
                        # exception #2 in the cache comment block).
                        if ts:
                            no_ts = False
                            day_key = ts.astimezone().strftime("%Y-%m-%d")
                        else:
                            # No parseable timestamp — keep the line (excluding it
                            # would under-count) but track it for diagnostics.
                            no_ts = True
                            entry["null_ts_lines"] += 1
                        if no_ts:
                            counters = entry["counters_no_ts"]
                        else:
                            counters = entry["counters_by_day"].setdefault(day_key, [0, 0, 0, 0])
                        counters[0] += 1  # raw_usage_lines
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
                        # populated; trust whichever is larger. (Also guarantees the
                        # cw >= cw_1h invariant that makes bucket costs linear.)
                        cw = max(cw, cw_5m + cw_1h)
                        # Dedup by message.id. Fallback: lines missing message.id
                        # but carrying a requestId dedup on that instead (same
                        # max/delta mechanics).
                        msg_id = m.get("id")
                        if not msg_id and data.get("requestId"):
                            msg_id = "req:" + str(data["requestId"])
                        if msg_id and msg_id in seen:
                            # Same message.id seen again: output_tokens grows as the
                            # response streams (later lines carry the larger, truer
                            # value). Take the per-field max and back-fill the delta
                            # into the sums this message was originally counted in.
                            rec = seen[msg_id]
                            u = rec["usage"]
                            new_u = {
                                "input_tokens": max(u["input_tokens"], inp),
                                "output_tokens": max(u["output_tokens"], out),
                                "cache_write": max(u["cache_write"], cw),
                                "cache_write_1h": max(u["cache_write_1h"], cw_1h),
                                "cache_read": max(u["cache_read"], cr),
                            }
                            if new_u != u:
                                sums = rec["sums"]
                                for i, field in enumerate((
                                        "input_tokens", "output_tokens", "cache_write",
                                        "cache_write_1h", "cache_read")):
                                    sums[i] += new_u[field] - u[field]
                                rec["usage"] = new_u
                                counters[3] += 1  # usage_upgraded_lines
                            continue
                        if not msg_id:
                            counters[2] += 1  # null_msg_id_lines
                        counters[1] += 1      # unique_messages
                        model_str = m.get("model", "") or ""
                        if no_ts:
                            # Fallback day key for null-ts lines: the file-local
                            # running first_ts's local date, else "unknown".
                            if first_ts_dt:
                                fday = first_ts_dt.astimezone().strftime("%Y-%m-%d")
                            else:
                                fday = "unknown"
                            bucket = entry["agg_no_ts"].setdefault(fday, {})
                        else:
                            bucket = entry["agg"].setdefault(day_key, {})
                        sums = bucket.setdefault(model_str, [0, 0, 0, 0, 0, 0])
                        sums[0] += inp
                        sums[1] += out
                        sums[2] += cw
                        sums[3] += cw_1h
                        sums[4] += cr
                        sums[5] += 1  # messages
                        if msg_id:
                            seen[msg_id] = {
                                "usage": {"input_tokens": inp, "output_tokens": out,
                                          "cache_write": cw, "cache_write_1h": cw_1h,
                                          "cache_read": cr},
                                "sums": sums,
                            }
                except Exception:
                    # Malformed line (bad JSON / unexpected types) — count it and
                    # keep scanning the rest of the file.
                    entry["skipped_lines"] += 1
                    continue
    except OSError:
        ok = False
    entry["first_ts"] = first_ts_dt.isoformat() if first_ts_dt else None
    # Active-time intervals: sort event epochs, gap-merge zero-width (t, t)
    # points, store as absolute [start_epoch, end_epoch, counts] triples (no
    # local-day split here — see the entry-shape docstring). Zero-duration
    # intervals (isolated events) are kept truthful (start == end); the
    # renderer pads to a visible width. Every model-tagged epoch is also in
    # `events`, so it falls inside exactly ONE merged interval — assigned by
    # a two-pointer walk over the sorted tag list.
    if events:
        events.sort()
        merged = _gap_merge([(t, t) for t in events], _GAP_MINUTES * 60)
        counts: list = [{} for _ in merged]
        model_events.sort()
        mi = 0
        for ep, cls in model_events:
            while merged[mi][1] < ep:
                mi += 1
            counts[mi][cls] = counts[mi].get(cls, 0) + 1
        entry["time"] = [[a, b, counts[i]] for i, (a, b) in enumerate(merged)]
    return entry, ok


def _merge_entry(sessions: dict, finfo: dict, entry: dict, start_str: str, end_str: str):
    """Merge one file entry into the sessions dict, day-filtering by key.

    `start_str <= day_key < end_str` (lexicographic on %Y-%m-%d) equals the
    per-message instant filter for midnight-aligned local ranges, because day
    keys were computed with per-datetime astimezone at parse time —
    identically to the cold path — with ONE sanctioned exception: a streamed
    message whose lines cross a local midnight that coincides with the range
    edge is attributed wholly (post-upgrade) to its FIRST line's day, whereas
    pre-cache builds instant-filtered each line pre-dedup and double-counted
    such a message across the two adjacent single-day queries (see exception
    #2 in the cache comment block; 0 occurrences in the real corpus). Costs
    are recomputed per (day, model_str) bucket from the summed integers
    (linear; see cache comment block).
    """
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
    sdata = sessions[sid]

    # first_msg comes only from the (single) main session file
    if not finfo["is_subagent"] and not sdata["first_msg"] and entry["first_msg"]:
        sdata["first_msg"] = entry["first_msg"]

    # Session first_ts = min over its files' per-file mins
    if entry["first_ts"]:
        try:
            etd = datetime.fromisoformat(entry["first_ts"])
            if sdata["first_ts"] is None or etd < sdata["first_ts"]:
                sdata["first_ts"] = etd
        except Exception:
            pass  # naive/aware mix or malformed — keep current (theoretical)

    def _add_day(day_key: str, models: dict):
        daily = sdata["daily_models"][day_key]
        for model_str, s in models.items():
            cls = classify_model(model_str)
            # Per-bucket cost using the exact model string (preferred over
            # class-level pricing — avoids mis-pricing Opus 4.7 as Opus 4).
            # cache_write_1h (s[3]) feeds ONLY the cost computation — the
            # usage buckets never stored it, same as the cold path.
            cost = cost_for_message({
                "input_tokens": s[0], "output_tokens": s[1], "cache_write": s[2],
                "cache_write_1h": s[3], "cache_read": s[4],
            }, model_str)
            for tgt in (sdata["models"][cls], daily[cls]):
                tgt["input_tokens"] += s[0]
                tgt["output_tokens"] += s[1]
                tgt["cache_write"] += s[2]
                tgt["cache_read"] += s[4]
                tgt["messages"] += s[5]
                tgt["cost"] += cost

    for day_key, models in entry["agg"].items():
        if start_str <= day_key < end_str:
            _add_day(day_key, models)
    # Null-ts usage bypassed the range filter in the cold path → always merge,
    # even if the fallback day lies outside the range (today's cold scan
    # emits an out-of-range day in daily_breakdown in that case; preserved).
    for day_key, models in entry["agg_no_ts"].items():
        _add_day(day_key, models)

    # Range-dependent diagnostic counters: day-filtered + always the no-ts part
    for day_key, c in entry["counters_by_day"].items():
        if start_str <= day_key < end_str:
            _SCAN_STATS["raw_usage_lines"] += c[0]
            _SCAN_STATS["unique_messages"] += c[1]
            _SCAN_STATS["null_msg_id_lines"] += c[2]
            _SCAN_STATS["usage_upgraded_lines"] += c[3]
    c = entry["counters_no_ts"]
    _SCAN_STATS["raw_usage_lines"] += c[0]
    _SCAN_STATS["unique_messages"] += c[1]
    _SCAN_STATS["null_msg_id_lines"] += c[2]
    _SCAN_STATS["usage_upgraded_lines"] += c[3]
    # Range-independent scalars
    _SCAN_STATS["skipped_lines"] += entry["skipped_lines"]
    _SCAN_STATS["prefiltered_lines"] += entry["prefiltered_lines"]
    _SCAN_STATS["null_ts_lines"] += entry["null_ts_lines"]
    _SCAN_STATS["time_event_lines"] += entry["time_event_lines"]


def scan_sessions(projects_dir: Path, start_dt: datetime, end_dt: datetime,
                  project_filter: Optional[str], use_cache: bool = True):
    """Scan all JSONL files; return (sessions, time_days).

    sessions: structured per-session usage data (sessions with no usage are
    dropped). time_days: per-day active-time dict covering every day of
    [start_dt, end_dt) — see _build_time_days.

    With use_cache=True (default), unchanged files (exact st_mtime_ns +
    st_size match) are served from ~/.claude/cache/cc-monitor/scan-cache.json
    instead of being re-parsed. The cache is range-agnostic: an entry always
    describes the whole file; range filtering happens at merge time. Pruning
    (mtime/peek) decides only whether a file participates in this query at
    all — a pruned file contributes nothing, not even its no-ts bucket,
    exactly matching the pre-cache behavior where a pruned file was never
    opened. use_cache=False (--no-cache) bypasses the cache entirely (no
    read, no write) — the always-available ground truth.
    """
    global _CACHE_ACTIVE
    start_epoch = start_dt.timestamp()
    end_epoch = end_dt.timestamp()

    # Reset diagnostic counters for this scan
    for _k in _SCAN_STATS:
        _SCAN_STATS[_k] = 0

    # Day-level range filtering (merge-time day-key comparison) is only exact
    # when both range bounds are naive local MIDNIGHTS. The CLI guarantees
    # this: resolve_range produces midnights and _parse_range_date rejects
    # bounds carrying a time component or UTC offset with exit(2). The check
    # below is defense-in-depth for non-CLI callers: a non-midnight bound
    # would be day-filtered the same way regardless of the cache, so we only
    # disable cache PERSISTENCE here (don't pollute the cache from an
    # unexpected call shape) — it does NOT make sub-day bounds exact.
    _midnight = datetime.min.time()
    use_cache = (use_cache and start_dt.tzinfo is None and end_dt.tzinfo is None
                 and start_dt.time() == _midnight and end_dt.time() == _midnight)
    _CACHE_ACTIVE = use_cache

    # Day-key bounds for merge-time filtering (end exclusive; lexicographic
    # comparison on %Y-%m-%d equals date comparison — see _merge_entry).
    start_str = start_dt.strftime("%Y-%m-%d")
    end_str = end_dt.strftime("%Y-%m-%d")

    cache_files: dict = _load_scan_cache() if use_cache else {}
    cache_dirty = False

    # Convert local-time range boundaries to UTC for comparing with message timestamps.
    # astimezone() on a naive datetime attaches the system local zone *per datetime*,
    # so DST transitions inside/across the range resolve correctly (a frozen
    # "current offset" would shift boundaries by an hour across DST changes).
    end_utc = end_dt.astimezone(timezone.utc)

    # Collect JSONL files that might contain in-range messages.
    # Lower bound: skip files last modified BEFORE the range start (no writes after
    # start ⇒ no in-range content). Do NOT skip on mtime after the range end —
    # cross-day sessions may have mtime beyond the range but still contain
    # in-range messages.
    all_files: list[dict] = []
    seen_paths: set = set()  # every existing jsonl path — cache prune keeps only these
    for p in projects_dir.rglob("*.jsonl"):
        try:
            st = p.stat()
        except OSError:
            # Deleted mid-scan or dangling symlink — skip, don't kill the scan
            continue
        path_str = str(p)
        seen_paths.add(path_str)
        if st.st_mtime < start_epoch:
            continue
        # Validated cache entry for this exact file state (or None)
        cache_entry = None
        if use_cache:
            _ce = cache_files.get(path_str)
            if _ce is not None and _ce["mtime_ns"] == st.st_mtime_ns and _ce["size"] == st.st_size:
                cache_entry = _ce
        # Upper bound: peek the first line's timestamp — content is authoritative.
        # st_birthtime is only a cheap pre-filter to decide whether the peek is
        # worth doing: rsync/cp/migration resets birthtime to the copy date, so a
        # birthtime after the range end does NOT prove the content is out of range.
        # For current-month queries the end is in the future, so the peek almost
        # never runs. Conservative: when in doubt, scan the file.
        birthtime = getattr(st, "st_birthtime", None)
        if birthtime is None or birthtime > end_epoch:
            if cache_entry is not None:
                # Validators guarantee the file is byte-identical to parse time,
                # so the stored peek_ts exactly replaces the physical peek.
                try:
                    if cache_entry["peek_ts"]:
                        _first_ts = datetime.fromisoformat(cache_entry["peek_ts"])
                        if _first_ts >= end_utc:
                            continue
                except Exception:
                    pass  # unparseable/naive — scan the file anyway, as today
            else:
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
            "mtime_ns": st.st_mtime_ns,
            "size": st.st_size,
            "cache_entry": cache_entry,
        })

    # Parse (or serve from cache) and merge, in collection order — preserves
    # the JSON sessions array order and first_msg first-wins semantics.
    sessions: dict[str, dict] = {}
    # Absolute (start_epoch, end_epoch, counts) across all files. counts may
    # be a cache-owned dict — _build_time_days copies before mutating.
    time_triples: list = []
    for finfo in all_files:
        entry = finfo["cache_entry"]
        if entry is not None:
            _SCAN_STATS["cache_hit_files"] += 1
        else:
            entry, parse_ok = parse_file(finfo["path"], finfo["is_subagent"])
            if use_cache:
                _SCAN_STATS["cache_miss_files"] += 1
            if not parse_ok:
                # I/O error: keep the partial counts (as the pre-cache scan
                # did) but never cache a partial entry.
                _SCAN_STATS["files_failed"] += 1
            elif use_cache:
                entry["mtime_ns"] = finfo["mtime_ns"]
                entry["size"] = finfo["size"]
                cache_files[str(finfo["path"])] = entry
                cache_dirty = True
        _merge_entry(sessions, finfo, entry, start_str, end_str)
        # Active-time intervals participate under the same pruning rules as
        # usage (a pruned file contributes nothing); range filtering happens
        # after the cross-file merge so midnight-bridging gaps survive.
        for s, e, c in entry["time"]:
            time_triples.append((s, e, c))

    if use_cache:
        # Prune entries whose file disappeared, then persist if anything changed.
        stale = [k for k in cache_files if k not in seen_paths]
        for k in stale:
            del cache_files[k]
        if stale:
            _SCAN_STATS["cache_pruned_files"] = len(stale)
            cache_dirty = True
        if cache_dirty:
            _write_scan_cache(cache_files)

    time_days = _build_time_days(time_triples, start_str, end_str)

    # Drop sessions with no usage
    filtered_sessions = {sid: s for sid, s in sessions.items() if any(
        u["messages"] > 0 for u in s["models"].values()
    )}
    return filtered_sessions, time_days


def _build_time_days(time_triples: list, start_str: str, end_str: str) -> dict:
    """Cross-file union merge of per-file active-time intervals.

    Works in the ABSOLUTE UTC-epoch domain (the cache's storage domain):
    globally sort and gap-merge the (start_epoch, end_epoch, counts) triples
    — counts SUM when intervals merge, so per merged interval they equal the
    global tally of its model-tagged events — then split each merged
    interval at local midnights and DST transitions via
    _split_interval_by_local_day. Equivalent to gap-merging the global event
    set, because every stored endpoint is a real event — and immune to the
    DST fall-back fold, where wall-clock seconds are non-monotonic in real
    time (a wall-domain merge fabricated active time across the repeated
    hour and missed real <=G gaps straddling it). Gaps spanning local
    midnight merge correctly (per-day merging would lose a 23:58→00:05
    bridge). The dominant model is resolved per MERGED interval; every day
    piece split from it carries that whole-interval dominant (counts are
    never split at midnight). Per day, the wall pieces are union-merged
    (sort, merge overlap/touch): a no-op on normal days (distinct merged
    intervals are > G apart and the wall mapping is monotonic) but required
    on fall-back days, where pieces from both sides of the fold may overlap
    on the wall axis — there the earlier piece's model wins (a None upgrades
    to the later piece's model), keeping durations exact at the cost of one
    label on a <=1h/year edge. Output invariants: intervals sorted, disjoint,
    0 <= s <= e <= 86400, sum == total_seconds. Returns {day_key:
    {"intervals": [[s, e, model], ...], "total_seconds": N}} — model is a
    MODEL_CLASSES member or None — covering EVERY day of
    [start_str, end_str); empty days included.
    """
    days: dict = {}
    cur = datetime.strptime(start_str, "%Y-%m-%d")
    end = datetime.strptime(end_str, "%Y-%m-%d")
    while cur < end:
        days[cur.strftime("%Y-%m-%d")] = {"intervals": [], "total_seconds": 0}
        cur += timedelta(days=1)
    if time_triples:
        # Counted variant of _gap_merge, same inclusive condition and epoch
        # domain. Sort key excludes counts (dicts don't order); counts are
        # copied before mutation — warm entries own theirs and a hit file's
        # dict is also what _write_scan_cache would re-serialize.
        gap = _GAP_MINUTES * 60
        merged: list = []
        for a, b, c in sorted(time_triples, key=lambda t: (t[0], t[1])):
            if merged and a - merged[-1][1] <= gap:
                if b > merged[-1][1]:
                    merged[-1][1] = b
                for cls, n in c.items():
                    merged[-1][2][cls] = merged[-1][2].get(cls, 0) + n
            else:
                merged.append([a, b, dict(c)])
        day_pieces: dict = {}
        for s_ep, e_ep, cnt in merged:
            model = _dominant_model(cnt)
            a = datetime.fromtimestamp(s_ep, timezone.utc)
            b = datetime.fromtimestamp(e_ep, timezone.utc)
            for day_key, s, e in _split_interval_by_local_day(a, b):
                if day_key in days:  # day-filter to the queried range
                    day_pieces.setdefault(day_key, []).append([s, e, model])
        for day_key, pieces in day_pieces.items():
            pieces.sort(key=lambda p: (p[0], p[1]))
            union: list = []
            for s, e, mdl in pieces:
                if union and s <= union[-1][1]:
                    if e > union[-1][1]:
                        union[-1][1] = e
                    if union[-1][2] is None:
                        union[-1][2] = mdl
                else:
                    union.append([s, e, mdl])
            rec = days[day_key]
            rec["intervals"] = union
            rec["total_seconds"] = sum(e - s for s, e, _ in union)
    return days


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
               include_sessions: bool = True, time_days: Optional[dict] = None):
    """Output structured JSON.

    time_days (additive top-level "time" section; JSON-only — the text output
    modes do not surface active time) is the scan's per-day active-time dict:
    {day_key: {"intervals": [[s, e, model], ...], "total_seconds": N}} with
    model the interval's dominant model class (or null) and intervals sorted,
    disjoint and 0 <= s <= e <= 86400 always (DST-transition days are
    split/clamped to wall-clock pieces — see _split_interval_by_local_day).
    """
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

    if time_days is not None:
        result["time"] = {"gap_minutes": _GAP_MINUTES, "days": time_days}

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
    parser.add_argument("--no-cache", action="store_true",
                        help="Bypass the incremental scan cache entirely (no read, no write); "
                             "every file is re-parsed. Ground truth for debugging/verification.")
    parser.add_argument("--include-quota", action="store_true",
                        help="Also fetch Anthropic's OAuth subscription quota (5h + 7d). "
                             "Only works for Pro/Max users who used `claude login`. "
                             "API-key users (Bedrock/Vertex) get no quota info — they have no cap.")
    parser.add_argument("--gap-minutes", type=int, default=DEFAULT_GAP_MINUTES,
                        help="Active-time sessionization gap in minutes (default "
                             f"{DEFAULT_GAP_MINUTES}); events closer than this merge "
                             "into one active interval. Changing it invalidates the scan cache.")
    parser.add_argument("--time-year", type=int, default=None, metavar="YYYY",
                        help="Emit per-day active-time totals for the whole year as JSON "
                             "and exit (no pricing/quota fetch). Respects --no-cache, "
                             "--gap-minutes and --project.")
    args = parser.parse_args()

    if args.gap_minutes < 1:
        print(f"Error: --gap-minutes must be >= 1 (got {args.gap_minutes})", file=sys.stderr)
        sys.exit(2)
    # Must be set BEFORE any cache load or scan: the cache header stamps it.
    global _GAP_MINUTES
    _GAP_MINUTES = args.gap_minutes

    projects_dir = Path.home() / ".claude" / "projects"
    if not projects_dir.exists():
        print("Error: ~/.claude/projects/ not found. Is Claude Code installed?", file=sys.stderr)
        sys.exit(1)

    # --time-year: active-time only, whole year. Skips load_pricing (no
    # network; per-bucket costs computed during merge fall back to
    # FALLBACK_PRICING internally and are discarded) and the quota fetch.
    # Warm runs lean entirely on the per-file cache (entries are
    # range-agnostic), well under 1s.
    if args.time_year is not None:
        if not (1970 <= args.time_year <= 9999):
            print(f"Error: --time-year must be within 1970-9999 (got {args.time_year})",
                  file=sys.stderr)
            sys.exit(2)
        y = args.time_year
        _sessions, time_days = scan_sessions(
            projects_dir, datetime(y, 1, 1), datetime(y + 1, 1, 1),
            args.project, use_cache=not args.no_cache)
        out = {
            "script_version": __version__,
            "year": y,
            "gap_minutes": _GAP_MINUTES,
            "days": {day: rec["total_seconds"] for day, rec in time_days.items()},
        }
        print(json.dumps(out, indent=2, ensure_ascii=False))
        sys.exit(0)

    # Load model pricing (LiteLLM with cache, or fallback)
    load_pricing()

    # Optionally fetch OAuth quota. Done BEFORE scanning so failures are fast.
    subscription_quota = fetch_oauth_usage() if args.include_quota else None

    start_dt, end_dt = resolve_range(args.range)
    range_label = f"{start_dt.strftime('%Y/%m/%d')} ~ {(end_dt - timedelta(days=1)).strftime('%Y/%m/%d')}"

    sessions, time_days = scan_sessions(projects_dir, start_dt, end_dt, args.project,
                                        use_cache=not args.no_cache)

    if not sessions:
        # Emit a well-formed empty result in JSON mode so callers (e.g. the Swift UI)
        # can parse stdout unconditionally. Prose-only output breaks JSONSerialization.
        # Active time can exist with zero usage sessions (e.g. user/system lines
        # only), so the "time" section carries the scan's real result here too.
        if args.json:
            empty = {
                "script_version": __version__,
                "pricing_source": _PRICING_SOURCE,
                "model_pricing": {mc: p for mc, p in MODEL_PRICING.items()},
                "sessions": [],
                "totals_by_model": {},
                "grand_total_cost": 0.0,
                "daily_breakdown": {},
                "time": {"gap_minutes": _GAP_MINUTES, "days": time_days},
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
                   include_sessions=not args.no_sessions, time_days=time_days)
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

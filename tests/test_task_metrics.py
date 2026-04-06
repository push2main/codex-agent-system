"""Unit tests for scripts/task_metrics.py core computation functions."""

from __future__ import annotations

import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

# Ensure the scripts directory is importable.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import task_metrics as tm


# --- normalize_status ---

class TestNormalizeStatus:
    def test_valid_string(self):
        assert tm.normalize_status("  SUCCESS ") == "success"

    def test_mixed_case(self):
        assert tm.normalize_status("Failed") == "failed"

    def test_none_returns_empty(self):
        assert tm.normalize_status(None) == ""

    def test_empty_string(self):
        assert tm.normalize_status("") == ""

    def test_whitespace_only(self):
        assert tm.normalize_status("   ") == ""


# --- safe_float ---

class TestSafeFloat:
    def test_valid_number(self):
        assert tm.safe_float("3.14") == 3.14

    def test_int_input(self):
        assert tm.safe_float(42) == 42.0

    def test_none_returns_zero(self):
        assert tm.safe_float(None) == 0.0

    def test_non_numeric_string(self):
        assert tm.safe_float("abc") == 0.0


# --- safe_int ---

class TestSafeInt:
    def test_valid_int(self):
        assert tm.safe_int("7") == 7

    def test_float_string_truncates(self):
        assert tm.safe_int(3.9) == 3

    def test_none_returns_default(self):
        assert tm.safe_int(None) == 0

    def test_fallback_used(self):
        assert tm.safe_int("bad", fallback=-1) == -1


# --- parse_timestamp ---

class TestParseTimestamp:
    def test_iso_with_z_suffix(self):
        result = tm.parse_timestamp("2026-04-01T12:00:00Z")
        assert result is not None
        assert result.year == 2026
        assert result.month == 4
        assert result.tzinfo is not None

    def test_iso_with_offset(self):
        result = tm.parse_timestamp("2026-04-01T14:00:00+02:00")
        assert result is not None
        assert result.hour == 14

    def test_empty_string_returns_none(self):
        assert tm.parse_timestamp("") is None

    def test_none_returns_none(self):
        assert tm.parse_timestamp(None) is None

    def test_invalid_string_returns_none(self):
        assert tm.parse_timestamp("not-a-date") is None


# --- classify_retry_failure_text ---

class TestClassifyRetryFailureText:
    def test_timeout(self):
        assert tm.classify_retry_failure_text("the process timed out") == "timeout"

    def test_missing_dependency(self):
        assert tm.classify_retry_failure_text("bash: jq: command not found") == "missing_dependency"

    def test_empty_returns_unknown(self):
        assert tm.classify_retry_failure_text("") == "unknown"

    def test_none_returns_unknown(self):
        assert tm.classify_retry_failure_text(None) == "unknown"

    def test_unrecognized_text(self):
        assert tm.classify_retry_failure_text("something completely novel happened") == "unknown"

    def test_sandbox_restriction(self):
        assert tm.classify_retry_failure_text("operation not permitted by sandbox") == "sandbox_restriction"


# --- task_has_persisted_success ---

class TestTaskHasPersistedSuccess:
    def test_completed_with_success_execution(self):
        task = {"status": "completed", "execution": {"result": "SUCCESS"}}
        assert tm.task_has_persisted_success(task) is True

    def test_failed_status_no_success_execution(self):
        task = {"status": "failed", "execution": {"result": "FAILURE"}}
        assert tm.task_has_persisted_success(task) is False

    def test_non_dict_returns_false(self):
        assert tm.task_has_persisted_success("not a dict") is False
        assert tm.task_has_persisted_success(None) is False

    def test_execution_context_success(self):
        task = {"status": "pending", "execution_context": {"result": "SUCCESS"}}
        assert tm.task_has_persisted_success(task) is True


# --- summarize_first_pass_success_records ---

class TestSummarizeFirstPassSuccess:
    def test_all_first_pass(self):
        records = [{"attempt": 1}, {"attempt": 0}, {"attempt": 1}]
        result = tm.summarize_first_pass_success_records(records)
        assert result["first_pass_success_rate"] == 1.0
        assert result["detected"] is False

    def test_half_first_pass(self):
        records = [{"attempt": 1}, {"attempt": 1}, {"attempt": 3}, {"attempt": 5}]
        result = tm.summarize_first_pass_success_records(records)
        assert result["first_pass_success_rate"] == 0.5
        assert result["detected"] is False

    def test_below_threshold(self):
        records = [{"attempt": 0}, {"attempt": 3}, {"attempt": 4}, {"attempt": 5}]
        result = tm.summarize_first_pass_success_records(records)
        assert result["first_pass_success_rate"] == 0.25
        assert result["detected"] is True

    def test_empty_list(self):
        result = tm.summarize_first_pass_success_records([])
        assert result["first_pass_success_rate"] == 0
        assert result["detected"] is False


# --- normalize_text ---

class TestNormalizeText:
    def test_collapses_whitespace(self):
        assert tm.normalize_text("  hello   world  ") == "hello world"

    def test_none(self):
        assert tm.normalize_text(None) == ""

    def test_mixed_case(self):
        assert tm.normalize_text("Hello World") == "hello world"

    def test_tabs_and_newlines(self):
        assert tm.normalize_text("foo\t\nbar") == "foo bar"


# --- first_non_empty_text ---

class TestFirstNonEmptyText:
    def test_returns_first_nonempty(self):
        assert tm.first_non_empty_text("", "  ", "hello") == "hello"

    def test_all_empty(self):
        assert tm.first_non_empty_text("", None, "  ") == ""

    def test_first_value_wins(self):
        assert tm.first_non_empty_text("alpha", "beta") == "alpha"


# --- normalize_project ---

class TestNormalizeProject:
    def test_returns_normalized(self):
        assert tm.normalize_project("  My Project  ") == "my project"

    def test_empty_returns_default(self):
        assert tm.normalize_project("") == "codex-agent-system"

    def test_none_returns_default(self):
        assert tm.normalize_project(None) == "codex-agent-system"


# --- normalize_datetime_utc ---

class TestNormalizeDatetimeUtc:
    def test_naive_gets_utc(self):
        naive = datetime(2026, 4, 1, 12, 0, 0)
        result = tm.normalize_datetime_utc(naive)
        assert result is not None
        assert result.tzinfo == timezone.utc

    def test_non_datetime_returns_none(self):
        assert tm.normalize_datetime_utc(None) is None
        assert tm.normalize_datetime_utc("2026-04-01") is None

    def test_aware_converts_to_utc(self):
        aware = datetime(2026, 4, 1, 14, 0, 0, tzinfo=timezone(timedelta(hours=2)))
        result = tm.normalize_datetime_utc(aware)
        assert result is not None
        assert result.hour == 12
        assert result.tzinfo == timezone.utc


# --- retry_failure_identity ---

class TestRetryFailureIdentity:
    def test_valid_entry(self):
        entry = {"project": "myproject", "task_id": "abc123"}
        assert tm.retry_failure_identity(entry) == "myproject::abc123"

    def test_missing_task_id(self):
        assert tm.retry_failure_identity({"project": "p"}) == ""

    def test_empty_project_uses_default(self):
        result = tm.retry_failure_identity({"project": "", "task_id": "t1"})
        assert result == "codex-agent-system::t1"


# --- effective_retry_classification ---

class TestEffectiveRetryClassification:
    def test_uses_existing_classification(self):
        entry = {"classification": "timeout"}
        assert tm.effective_retry_classification(entry) == "timeout"

    def test_falls_back_to_error_text(self):
        entry = {"classification": "unknown", "error_text": "the process timed out"}
        assert tm.effective_retry_classification(entry) == "timeout"

    def test_unknown_when_no_info(self):
        entry = {"classification": "", "error_text": ""}
        assert tm.effective_retry_classification(entry) == "unknown"


# --- manual_recovery_records ---

class TestManualRecoveryRecords:
    def test_counts_manual(self):
        records = [
            {"source": "manual_recovery"},
            {"source": "auto"},
            {"source": "manual_recovery"},
        ]
        assert tm.manual_recovery_records(records) == 2

    def test_empty_list(self):
        assert tm.manual_recovery_records([]) == 0

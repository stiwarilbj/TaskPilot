"""Content-free, explicitly linked fault episodes. Never infer causality by time.

Reports are bounded, task-owned and short-lived. Recovery claims only coalesce
the same episode/route/attempt; they neither grant execution nor renew budgets.
"""
from collections import Counter, OrderedDict
from dataclasses import dataclass, field
from threading import RLock
import time
import uuid

CAUSES = frozenset({"unknown", "transport", "gateway_unavailable", "configuration",
    "credentials", "provider_quota", "provider_capacity", "model_unavailable",
    "invalid_output", "command_timeout", "native_protocol"})
STAGES = frozenset({"health_check", "connection", "model_request", "native_action",
    "recovery", "waiting", "draining", "terminal"})
ROUTES = {"transport": "reconnect", "gateway_unavailable": "gateway_restart",
    "configuration": "attention", "credentials": "attention",
    "provider_quota": "provider_policy", "provider_capacity": "provider_policy",
    "model_unavailable": "provider_policy", "invalid_output": "format_repair",
    "command_timeout": "reconcile", "native_protocol": "reconcile", "unknown": "none"}
VERSION = 1


def validate_link(value):
    if type(value) is not dict or set(value) != {"version", "child_id", "parent_id"} or type(value['version']) is not int or value['version'] != VERSION:
        raise ValueError('invalid fault link')
    for name in ('child_id', 'parent_id'):
        text = value[name]
        if type(text) is not str or len(text) != 36 or str(uuid.UUID(text)) != text:
            raise ValueError('invalid fault link identity')
    if value['child_id'] == value['parent_id']: raise ValueError('cyclic fault link')
    return dict(value)


def validate_event(value):
    if type(value) is not dict or set(value) != {"version", "fault_id", "sequence", "cause", "stage"}:
        raise ValueError("invalid fault fields")
    if (type(value["version"]) is not int or value["version"] != VERSION or
            type(value["sequence"]) is not int or not 1 <= value["sequence"] <= 16 or
            type(value["fault_id"]) is not str or len(value["fault_id"]) != 36 or
            str(uuid.UUID(value["fault_id"])) != value["fault_id"] or
            type(value["cause"]) is not str or value["cause"] not in CAUSES or
            type(value["stage"]) is not str or value["stage"] not in STAGES):
        raise ValueError("invalid fault value")
    return dict(value)


@dataclass
class Report:
    cause: str
    first_stage: str
    started: float
    sequence: int = 0
    consequences: Counter = field(default_factory=Counter)
    claims: set = field(default_factory=set)
    suppressed: int = 0


class FaultReports:
    def __init__(self, *, clock=time.monotonic, publish=None, publish_link=None, capacity=32, ttl=120):
        self.clock, self.publish, self.publish_link = clock, publish, publish_link
        self.capacity, self.ttl = max(1, min(64, capacity)), max(1, min(120, ttl))
        self.reports = OrderedDict()
        self.aliases = OrderedDict()
        self.lock = RLock()

    def _prune(self):
        now = self.clock()
        for key, report in list(self.reports.items()):
            if not 0 <= now - report.started < self.ttl:
                del self.reports[key]
        for key, parent in list(self.aliases.items()):
            if parent not in self.reports: del self.aliases[key]

    def record(self, cause, stage, *, link=None):
        if cause not in CAUSES or stage not in STAGES:
            raise ValueError("unknown fault vocabulary")
        with self.lock:
            self._prune()
            link = self.aliases.get(link, link)
            report = self.reports.get(link)
            # An explicit parent is necessary but cannot merge unrelated causes.
            if report is None or not (report.cause == cause or
                    report.cause == "gateway_unavailable" and cause == "transport"):
                link = str(uuid.uuid4())
                report = Report(cause, stage, self.clock())
                self.reports[link] = report
                while len(self.reports) > self.capacity:
                    self.reports.popitem(last=False)
            if report.sequence < 16:
                report.sequence += 1
                if report.sequence > 1 and sum(report.consequences.values()) < 15:
                    report.consequences[stage] += 1
                event = dict(version=VERSION, fault_id=link, sequence=report.sequence,
                             cause=report.cause, stage=stage)
                if self.publish is not None:
                    try: self.publish(validate_event(event))
                    except Exception: pass  # Diagnostics cannot fail task work.
            return link

    def note(self, link, stage):
        with self.lock:
            self._prune()
            link = self.aliases.get(link, link)
            report = self.reports.get(link)
            return self.record(report.cause, stage, link=link) if report else None

    def adopt(self, event):
        """Only validated, fresh metadata from the current live host calls this."""
        event = validate_event(event)
        if event["sequence"] != 1 or event["cause"] not in {"gateway_unavailable", "configuration", "credentials"}:
            raise ValueError("invalid gateway fault")
        with self.lock:
            self._prune()
            key = event["fault_id"]
            if key in self.reports:
                return key if self.reports[key].cause == event["cause"] else None
            self.reports[key] = Report(event["cause"], event["stage"], self.clock())
            while len(self.reports) > self.capacity: self.reports.popitem(last=False)
            return self.record(event["cause"], event["stage"], link=key)

    def attach(self, child, parent):
        """Late host evidence may explain this specific interrupted connection.

        Only the explicit reconnect operation supplies the child; never scan for
        a nearby transport error. Preserve its spent claim and bounded counts.
        """
        with self.lock:
            self._prune()
            child, parent = self.aliases.get(child, child), self.aliases.get(parent, parent)
            first, root = self.reports.get(child), self.reports.get(parent)
            if child == parent: return True
            if not first or not root or first.cause != 'transport' or root.cause != 'gateway_unavailable':
                return False
            root.claims.update(first.claims)
            for stage in [first.first_stage, *first.consequences.elements()]:
                if sum(root.consequences.values()) >= 15: break
                root.consequences[stage] += 1
            root.suppressed = min(1_000_000_000, root.suppressed + first.suppressed)
            self.aliases[child] = parent
            while len(self.aliases) > 64: self.aliases.popitem(last=False)
            del self.reports[child]
            if self.publish_link is not None:
                try: self.publish_link(validate_link(dict(version=VERSION, child_id=child, parent_id=parent)))
                except Exception: pass
            self.note(parent, 'connection')
            return True

    def claim(self, link, route, *, attempt=1):
        with self.lock:
            self._prune()
            link = self.aliases.get(link, link)
            report = self.reports.get(link)
            if (report is None or not (ROUTES[report.cause] == route or
                    report.cause == "gateway_unavailable" and route == "reconnect") or route == "none" or
                    type(attempt) is not int or not 1 <= attempt <= 16):
                return False
            key = (route, attempt)
            if key in report.claims:
                report.suppressed = min(1_000_000_000, report.suppressed + 1)
                return False
            report.claims.add(key)
            self.note(link, "recovery")
            return True


def failure_cause(kind):
    return {"quota": "provider_quota", "temporary": "provider_capacity",
            "unavailable": "model_unavailable", "transport": "transport",
            "credentials": "credentials", "configuration": "configuration",
            "invalid_output": "invalid_output"}.get(kind, "unknown")

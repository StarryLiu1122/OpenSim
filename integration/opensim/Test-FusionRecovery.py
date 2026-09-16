"""Supervise only a dedicated, already built reference instance; never a user server.

The normal experiment runs first, then real process/Bot interruption, cursor loss,
expired sessions and cold restart. Logs stay local because upstream logs contain
session identifiers. Requires Windows PowerShell for owned-child PID inspection.
"""
import argparse
import copy
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import time
import urllib.request
import urllib.error
from urllib.parse import urlparse

spec = importlib.util.spec_from_file_location("fusion_experiment", Path(__file__).with_name("Test-Fusion.py"))
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)


class Recovery:
    def __init__(self, source, output):
        self.source = Path(source).resolve(); self.output = Path(output).resolve()
        self.output.mkdir(parents=True)
        self.config = self.source / "reference-private.json"
        self.private = json.loads(self.config.read_text(encoding="utf-8-sig"))
        url = urlparse(self.private["url"])
        if url.hostname != "127.0.0.1": raise RuntimeError("Only isolated loopback instances are supported")
        with socket.socket() as probe:
            if probe.connect_ex((url.hostname, url.port)) == 0: raise RuntimeError("Instance must be stopped before this test")
        self.ini = self.source / "bin/OpenSim.ini"
        self.original_ini = self.ini.read_text(encoding="utf-8-sig")
        self.server = None; self.log = None; self.starts = 0; self.checks = []

    def check(self, ok, name):
        self.checks.append(dict(name=name, passed=bool(ok)))
        (self.output / "report.json").write_text(json.dumps(dict(test="fp-cold-restart-and-faults", passed=all(c["passed"] for c in self.checks), checks=self.checks), indent=2) + "\n", encoding="utf-8")
        print(("PASS " if ok else "FAIL ") + name, flush=True)
        if not ok: raise AssertionError(name)

    def start(self, expired=False):
        text = re.sub(r"(?m)^(EventCapacity|SessionExpires) = .*\n?", "", self.original_ini)
        # A small supported production buffer makes overflow deterministic.
        if self.starts > 0: text += "\nEventCapacity = 32\n"
        if expired: text += "SessionExpires = 2020-01-01T00:00:00Z\n"
        self.ini.write_text(text, encoding="utf-8")
        self.starts += 1
        self.log = (self.output / ("private-server-" + str(self.starts) + ".txt")).open("wb")
        env = dict(os.environ, DOTNET_CLI_HOME=str(self.source / ".dotnet-home"), DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_SKIP_FIRST_TIME_EXPERIENCE="1")
        self.server = subprocess.Popen(["dotnet", "OpenSim.dll", "-console=basic"], cwd=self.source / "bin", stdin=subprocess.PIPE, stdout=self.log, stderr=subprocess.STDOUT, env=env)
        self.exp = module.Experiment(str(self.config), self.output / ("epoch-" + str(self.starts)))
        until = time.monotonic() + 90
        while time.monotonic() < until:
            if self.server.poll() is not None: raise RuntimeError("Reference server exited during startup")
            try:
                caps = self.exp.call("GetCapabilities")
                if expired and caps.get("error") == "UNAUTHORIZED_OR_EXPIRED_SESSION": return
                if caps.get("state") == "completed":
                    self.exp.epoch = caps["world_epoch"]
                    # Scene module registration precedes final logins-enabled state.
                    time.sleep(2); return
            except (OSError, TimeoutError, json.JSONDecodeError): pass
            time.sleep(.5)
        raise RuntimeError("Reference startup timeout")

    def stop(self, crash=False):
        if self.server and self.server.poll() is None:
            if crash:
                # taskkill targets this test-owned server and its Bot children only.
                subprocess.run(["taskkill", "/PID", str(self.server.pid), "/T", "/F"], capture_output=True, check=True)
            else:
                self.server.stdin.write(b"shutdown\n"); self.server.stdin.flush()
            try: self.server.wait(timeout=35)
            except subprocess.TimeoutExpired:
                subprocess.run(["taskkill", "/PID", str(self.server.pid), "/T", "/F"], capture_output=True)
                self.server.wait(timeout=10); raise
        if self.server: self.server.stdin.close()
        self.server = None
        if self.log: self.log.close(); self.log = None

    def kill_owned_bot(self):
        script = "$p=Get-CimInstance Win32_Process | Where-Object {$_.ParentProcessId -eq " + str(self.server.pid) + " -and $_.CommandLine -like '*ReferenceBot.dll*--worker*'}; if(@($p).Count -ne 1){throw 'Expected one owned Bot'}; Stop-Process -Id $p.ProcessId"
        subprocess.run(["powershell", "-NoProfile", "-Command", script], capture_output=True, check=True)

    def run(self):
        try:
            self.start(); self.exp.run(clean_previous=True)
            self.check(all(x["passed"] for x in self.exp.checks), "complete real-region experiment passes in a newly built directory")
            saved = json.loads((self.exp.output / "restart-input.json").read_text())
            first_export = self.exp.call("TelemetryExport")
            second_export = self.exp.call("TelemetryExport")
            self.check(first_export["state"] == second_export["state"] == "completed" and all(r["operation"] != "TelemetryExport" for r in second_export["data"]["receipts"]), "repeated telemetry export does not recursively embed older exports")
            old_epoch = self.exp.epoch
            self.stop(); self.start()
            self.check(self.exp.epoch != old_epoch, "cold module restart generates a new world epoch")
            prior = self.exp.call("ActionReceipt", dict(request_id=saved["request"]["request_id"], receipt_epoch=old_epoch))
            self.check(prior["state"] == "completed" and prior["data"] == saved["receipt"], "completed receipt survives restart with its original outcome")
            self.check(self.exp.send(saved["request"]).get("error") == "EPOCH_MISMATCH", "old-epoch command is never executed again")
            state = self.exp.state()
            boxes = [e for e in state["entities"] if e["kind"] == "object_group" and e["members"][0]["name"] == "Idempotent"]
            self.check(len(boxes) == 1, "restart preserves exactly one object from the repeated mutation")
            cursor = state["snapshot_seq"]; box = boxes[0]["source_id"]
            for i in range(40):
                r = self.exp.mutation("Move", dict(group_id=box, position=[120 + i % 2, 120, 1]))
                if r["state"] != "completed": raise RuntimeError("Overflow fixture mutation failed")
            self.check(self.exp.call("SimEventStream", dict(after_seq=cursor, limit=128)).get("error") == "RESYNC_REQUIRED", "overflowed event cursor explicitly requires a new snapshot")
            current = self.exp.state()
            resumed = self.exp.call("SimEventStream", dict(after_seq=current["snapshot_seq"], limit=128))
            self.check(resumed["state"] == "completed" and not resumed["data"]["events"], "snapshot boundary resumes without duplicate module subscriptions")
            for i in range(3):
                spawned = self.exp.await_result(self.exp.call("AgentSpawn"))
                self.check(spawned["state"] == "completed", "repeated Bot login " + str(i + 1))
                turned = self.exp.await_result(self.exp.call("AgentAction", dict(action="TURN", yaw=.25 * (i + 1))))
                self.check(turned["state"] == "completed", "repeated Bot actual turn " + str(i + 1))
                despawned = self.exp.await_result(self.exp.call("AgentDespawn"))
                self.check(despawned["state"] == "completed", "repeated Bot clean logout " + str(i + 1))
            self.check(self.exp.await_result(self.exp.call("AgentSpawn"))["state"] == "completed", "Bot available for child-loss test")
            pos = self.exp.avatar()["position"]
            move = self.exp.call("AgentAction", dict(action="MOVE_TO", position=[pos[0]+20, pos[1], pos[2]]))
            self.check(move["state"] == "pending", "action pending before actual Bot process loss")
            self.kill_owned_bot()
            failed = self.exp.await_result(move)
            self.check(failed["state"] == "failed" and failed["error"] == "BOT_LOST", "killed Bot produces failed receipt rather than fabricated success")
            self.stop(); self.start()
            self.check(not any(e["kind"] == "avatar" for e in self.exp.state()["entities"]), "restart clears disconnected test Avatar presence")
            self.check(self.exp.await_result(self.exp.call("AgentSpawn"))["state"] == "completed", "Bot reconnects after server restart")
            pos = self.exp.avatar()["position"]
            pending = self.exp.call("AgentAction", dict(action="MOVE_TO", position=[pos[0]+20, pos[1], pos[2]]))
            self.check(pending["state"] == "pending", "prepared movement exists before server termination")
            interrupted_epoch = self.exp.epoch
            self.stop(crash=True); self.start()
            uncertain = self.exp.call("ActionReceipt", dict(request_id=pending["request_id"], receipt_epoch=interrupted_epoch))
            self.check(uncertain["state"] == "completed" and uncertain["data"]["state"] == "result_unknown" and uncertain["data"]["error"] == "PREVIOUS_EPOCH_INTERRUPTED", "interrupted prepared receipt remains result_unknown after server death")
            self.check(not any(e["kind"] == "avatar" for e in self.exp.state()["entities"]), "interrupted action is not replayed and does not spawn a new Bot")
            self.check(self.exp.await_result(self.exp.call("AgentSpawn"))["state"] == "completed", "explicit spawn reconnects after crash-stale original presence is cleared")
            self.check(self.exp.await_result(self.exp.call("AgentDespawn"))["state"] == "completed", "reconnected Bot exits cleanly after crash recovery")
            self.stop(); self.start(expired=True)
            self.check(self.exp.call("GetCapabilities").get("error") == "UNAUTHORIZED_OR_EXPIRED_SESSION", "expired authenticated session is rejected on a real HTTP request")
            legacy = urllib.request.Request(self.private["url"] + "/fusion/v0/regions/" + self.private["region_id"] + "/commands", b"{}", {"Authorization": "Bearer " + self.private["token"], "Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(legacy) as response: legacy_status = response.status
            except urllib.error.HTTPError as error: legacy_status = error.code
            self.check(legacy_status == 401, "legacy reference endpoint cannot bypass session expiry")
            self.stop()
            bot_logs = list((self.source / "bin/fusion-data").glob("*-bot.log"))
            self.check(bool(bot_logs) and all("PlatformNotSupportedException" not in p.read_text(encoding="utf-8", errors="replace") and "Thread.Abort" not in p.read_text(encoding="utf-8", errors="replace") for p in bot_logs), "normal and interrupted Bot runs contain no unsupported Thread.Abort exception")
        finally:
            self.stop(); self.ini.write_text(self.original_ini, encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("source"); parser.add_argument("output")
    args = parser.parse_args(); suite = Recovery(args.source, args.output)
    try: suite.run()
    except BaseException as error:
        suite.checks.append(dict(name="suite completion", passed=False, error=str(error)))
        suite.check(False, "fault suite completed")

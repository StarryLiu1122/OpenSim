"""Real-region mock-platform experiment, Python 3 standard library only.

Does not print credentials. Requires an isolated empty running V4 reference with
the gateway installed. Every request/receipt is retained without Authorization.
"""
import argparse
import copy
import datetime as dt
import hashlib
import json
import math
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path


class Experiment:
    def __init__(self, configuration, output):
        self.config = json.loads(Path(configuration).read_text(encoding="utf-8-sig"))
        self.output = Path(output)
        self.output.mkdir(parents=True)  # Reports are never overwritten.
        self.url = self.config["url"] + "/fusion/v1/regions/" + self.config["region_id"] + "/commands"
        self.epoch = ""
        self.trace = str(uuid.uuid4())
        self.sequences = {"operator": 0, "observer": 0, "secondary": 0}
        self.records, self.checks = [], []

    def check(self, result, label):
        self.checks.append({"name": label, "passed": bool(result)})
        print(("PASS " if result else "FAIL ") + label, flush=True)
        self.save()
        if not result:
            raise AssertionError(label)

    def command(self, operation, payload=None, subject="operator", seconds=30):
        self.sequences[subject] += 1
        return dict(fp_version="0.2", world_id=self.config["region_id"], region_id=self.config["region_id"],
                    request_id=str(uuid.uuid4()), trace_id=self.trace, world_epoch=self.epoch, origin="mock-platform",
                    source_seq=self.sequences[subject], operation=operation,
                    expires_at=(dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=seconds)).isoformat(), payload=payload or {})

    def send(self, command, subject="operator", token=None):
        token = token or self.config["token" if subject == "operator" else subject + "_token"]
        req = urllib.request.Request(self.url, json.dumps(command).encode(), {"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                code, body = response.status, json.loads(response.read())
        except urllib.error.HTTPError as e:
            code, body = e.code, json.loads(e.read())
        self.records.append(dict(subject=subject, request=command, http_status=code, receipt=body))
        self.save()
        return body

    def call(self, op, payload=None, subject="operator", seconds=30):
        return self.send(self.command(op, payload, subject, seconds), subject)

    def await_result(self, reply):
        end = time.monotonic() + 65
        while reply.get("state") == "pending" and time.monotonic() < end:
            time.sleep(.15)
            query = self.call("ActionReceipt", dict(request_id=reply["request_id"], receipt_epoch=reply["world_epoch"]))
            if query.get("state") != "completed":
                raise RuntimeError("Receipt lookup failed: " + query.get("error", ""))
            reply = query["data"]
        return reply

    def state(self, subject="operator"):
        r = self.call("WorldStateSubscribe", subject=subject)
        if r.get("state") != "completed": raise RuntimeError("Snapshot failed")
        return r["data"]

    def mutation(self, op, payload, subject="operator"):
        state = self.state(subject)
        return self.call("WorldMutation", dict(expected_seq=state["snapshot_seq"], operation=op, payload=payload), subject)

    def avatar(self):
        return next(e for e in self.state()["entities"] if e["kind"] == "avatar" and e["source_id"] == self.config["owner_id"])

    def save(self):
        (self.output / "commands-and-receipts.json").write_text(json.dumps(self.records, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        (self.output / "report.json").write_text(json.dumps(dict(test="fp-mock-platform", trace_id=self.trace, world_epoch=self.epoch, passed=bool(self.checks) and all(c["passed"] for c in self.checks), checks=self.checks), indent=2) + "\n", encoding="utf-8")

    def run(self, clean_previous=False):
        caps = self.call("GetCapabilities")
        self.check(caps.get("state") == "completed", "FP capabilities discovered")
        self.epoch = caps["world_epoch"]
        initial = self.state()
        if clean_previous:
            allowed_names = {"FP controlled door", "Idempotent", "Secondary-owned", "Movement barrier", "Occluder"}
            for entity in initial["entities"]:
                if entity["kind"] != "object_group" or len(entity["members"]) != 1 or entity["members"][0]["name"] not in allowed_names or entity["owner_id"] not in (self.config["owner_id"], self.config["secondary_owner"]):
                    raise RuntimeError("Cleanup refused: unexpected entity in test region")
            for entity in initial["entities"]:
                subject = "operator" if entity["owner_id"] == self.config["owner_id"] else "secondary"
                removed = self.mutation("Delete", dict(group_id=entity["source_id"]), subject)
                if removed["state"] != "completed": raise RuntimeError("Fixture cleanup failed")
            initial = self.state()
        self.check(not initial["entities"], "isolated region is empty")
        (self.output / "initial-state.json").write_text(json.dumps(initial, indent=2) + "\n")
        run_id = str(uuid.uuid4())
        self.check(self.call("ExperimentControl", dict(action="start", experiment_id=run_id))["state"] == "completed", "experiment started")
        spawn = self.await_result(self.call("AgentSpawn"))
        self.check(spawn["state"] == "completed" and spawn["data"]["avatar_present"], "FP spawn confirmed by original region")
        start = self.avatar()["position"]
        goal = [start[0] + 3, start[1], start[2]]
        move = self.await_result(self.call("AgentAction", dict(action="MOVE_TO", position=goal)))
        self.check(move["state"] == "completed" and math.dist(move["data"]["position"][:2], goal[:2]) < .55, "MOVE_TO reached observed target")
        turn = self.await_result(self.call("AgentAction", dict(action="TURN", yaw=math.pi / 2)))
        self.check(turn["state"] == "completed" and abs(turn["data"]["rotation"][2] - math.sqrt(.5)) < .045, "TURN confirmed by region quaternion")
        inspect = self.call("AgentAction", dict(action="INSPECT"))
        self.check(inspect["state"] == "completed", "INSPECT reads authoritative avatar")
        pos = self.avatar()["position"]
        door = self.mutation("CreateDoor", dict(name="FP controlled door", position=[pos[0], pos[1] + 2, 1.5], size=[2, .2, 3]))
        self.check(door["state"] == "completed", "owned interactive door created")
        door_id = door["data"]["entity_id"].split("/")[1]
        interaction = self.call("AgentAction", dict(action="INTERACT", group_id=door_id))
        self.check(interaction["state"] == "completed" and interaction["data"]["active"], "nearby visible door opens with observed rotation")
        # Place a wall between the avatar and the door; conservative visibility rejects it.
        occluder = self.mutation("CreateBox", dict(name="Occluder", position=[pos[0], pos[1] + 1, 1.5], size=[2, .2, 3]))
        self.check(occluder["state"] == "completed", "occlusion fixture created")
        self.check(self.call("AgentAction", dict(action="INTERACT", group_id=door_id)).get("error") == "INTERACTION_OCCLUDED", "interaction cannot pass through a wall")
        self.check(self.mutation("Delete", dict(group_id=occluder["data"]["entity_id"].split("/")[1]))["state"] == "completed", "occlusion fixture removed")
        # Duplicate delivery must return exactly the prior receipt and create only one object.
        state = self.state()
        duplicate = self.command("WorldMutation", dict(expected_seq=state["snapshot_seq"], operation="CreateBox", payload=dict(name="Idempotent", position=[120, 120, 1], size=[1, 1, 1])))
        first, again = self.send(duplicate), self.send(duplicate)
        self.check(first["state"] == "completed" and first == again, "identical mutation retry returns original receipt")
        self.check(sum(e.get("kind") == "object_group" and e["members"][0]["name"] == "Idempotent" for e in self.state()["entities"]) == 1, "duplicate delivery creates exactly one object")
        altered = copy.deepcopy(duplicate); altered["payload"]["payload"]["name"] = "changed"
        self.check(self.send(altered).get("error") == "REQUEST_REUSED", "changed payload cannot reuse request identity")
        oldseq = self.command("WorldMutation", dict(expected_seq=-1, operation="Delete", payload=dict(group_id=door_id))); oldseq["source_seq"] = 1
        self.check(self.send(oldseq).get("error") == "SOURCE_SEQUENCE_REUSED_OR_OUT_OF_ORDER", "out-of-order source message rejected")
        self.check(self.call("WorldMutation", dict(expected_seq=-1, operation="Delete", payload=dict(group_id=door_id))).get("error") == "STATE_CONFLICT", "stale observation cannot mutate world")
        foreign = self.mutation("CreateBox", dict(name="Secondary-owned", position=[140, 140, 1], size=[1, 1, 1]), "secondary")
        self.check(foreign["state"] == "completed", "second authenticated writer owns independent object")
        foreign_id = foreign["data"]["entity_id"].split("/")[1]
        self.check(self.mutation("Move", dict(group_id=foreign_id, position=[142, 140, 1])).get("error") == "FORBIDDEN", "cross-owner mutation rejected in original region")
        foreign_after = next(e for e in self.state()["entities"] if e["source_id"] == foreign_id)
        self.check(foreign_after["position"] == [140, 140, 1], "cross-owner rejection preserves original position")
        observer = self.state("observer")
        self.check("owner_id" not in json.dumps(observer), "observer snapshot hides ownership fields")
        self.check(self.call("WorldMutation", {}, "observer").get("error") == "FORBIDDEN", "observer cannot mutate")
        self.check(self.call("ActionReceipt", dict(request_id=duplicate["request_id"], receipt_epoch=self.epoch), "observer").get("error") == "FORBIDDEN", "receipts remain scoped to authenticated subject")
        self.check(self.call("AgentAction", dict(action="FLY")).get("error") == "UNSUPPORTED_ACTION", "unsupported action explicitly rejected")
        self.check(self.call("AgentAction", dict(action="INSPECT"), seconds=-1).get("error") == "INVALID_DEADLINE", "expired command rejected")
        bad_epoch = self.command("AgentDespawn"); bad_epoch["world_epoch"] = str(uuid.uuid4())
        self.check(self.send(bad_epoch).get("error") == "EPOCH_MISMATCH", "old epoch cannot repeat side effects")
        echo = self.command("WorldMutation", {}); echo["origin"] = "opensim"
        self.check(self.send(echo).get("error") == "UNTRUSTED_ORIGIN", "event echo cannot be injected as a command")
        forged = self.command("AgentDespawn"); forged["subject"] = "operator"
        self.check(self.send(forged).get("error") == "INVALID_FIELDS", "payload cannot forge authenticated subject")
        self.check(self.send(self.command("WorldStateSubscribe"), token="x" * 64).get("error") == "UNAUTHORIZED_OR_EXPIRED_SESSION", "invalid token rejected")
        pos = self.avatar()["position"]
        moving = self.call("AgentAction", dict(action="MOVE_TO", position=[pos[0] + 16, pos[1], pos[2]]))
        self.check(moving["state"] == "pending", "long action has a pending receipt")
        self.check(self.call("CancelAction", dict(request_id=moving["request_id"]))["state"] == "completed", "pending action accepts explicit cancellation")
        self.check(self.await_result(moving)["state"] == "cancelled", "cancelled action reaches queryable terminal state")
        pos = self.avatar()["position"]
        barrier = self.mutation("CreateBox", dict(name="Movement barrier", position=[pos[0] + 2, pos[1], 1.5], size=[.5, 8, 3]))
        self.check(barrier["state"] == "completed", "unreachable-target barrier created")
        blocked = self.await_result(self.call("AgentAction", dict(action="MOVE_TO", position=[pos[0] + 8, pos[1], pos[2]]), seconds=4))
        self.check(blocked["state"] == "failed" and blocked["error"] == "ACTION_TIMEOUT", "blocked physical movement times out without success")
        self.check(self.avatar()["position"][0] < pos[0] + 3, "BulletSim prevented crossing the barrier")
        self.check(self.mutation("Delete", dict(group_id=barrier["data"]["entity_id"].split("/")[1]))["state"] == "completed", "barrier cleaned up")
        # Disconnect/reconnect is modeled as a lost polling connection: no action replay.
        cursor = initial["snapshot_seq"]
        collected = []
        while True:
            batch = self.call("SimEventStream", dict(after_seq=cursor, limit=128))
            self.check(batch["state"] == "completed", "cursor-based reconnect reads retained events")
            collected.extend(batch["data"]["events"]); cursor = batch["data"]["next_seq"]
            if cursor >= batch["data"]["head_seq"]: break
        self.check([e["seq"] for e in collected] == list(range(initial["snapshot_seq"] + 1, cursor + 1)), "event sequence has no duplicates or gaps")
        self.check(any(e["kind"] == "interaction" and e["trace_id"] == self.trace for e in collected), "interaction event retains experiment trace")
        (self.output / "events.json").write_text(json.dumps(collected, indent=2) + "\n")
        despawn = self.await_result(self.call("AgentDespawn"))
        self.check(despawn["state"] == "completed" and not despawn["data"]["avatar_present"], "FP despawn confirms Avatar absence and clean child exit")
        self.check(self.call("ExperimentControl", dict(action="stop", experiment_id=run_id))["state"] == "completed", "experiment stopped")
        telemetry = self.call("TelemetryExport")
        self.check(telemetry["state"] == "completed", "FP telemetry export produced offline-readable data")
        (self.output / "telemetry.json").write_text(json.dumps(telemetry["data"], indent=2) + "\n")
        (self.output / "restart-input.json").write_text(json.dumps(dict(old_epoch=self.epoch, request=duplicate, receipt=first), indent=2) + "\n")
        self.save()
        manifest = [{"path": p.name, "bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(self.output.glob("*.json"))]
        (self.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("configuration"); parser.add_argument("output")
    parser.add_argument("--clean-previous", action="store_true", help="Delete only this test's recognized single-part fixtures, with owner checks")
    args = parser.parse_args()
    experiment = Experiment(args.configuration, args.output)
    try:
        experiment.run(args.clean_previous)
    except BaseException as error:
        experiment.checks.append(dict(name="experiment completion", passed=False, error=type(error).__name__ + ": " + str(error)))
        experiment.save()
        raise

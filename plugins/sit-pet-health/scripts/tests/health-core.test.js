"use strict";

const assert = require("node:assert/strict");
const { levelFor, vitalityFor, newState, stepHealth, updateCodexSessions } = require("../health-core.js");
const config = {
  graceSeconds: 1800,
  lazySeconds: 3600,
  wiltedSeconds: 5400,
  sickSeconds: 7200,
  fullBreakSeconds: 300,
  partialBreakStartSeconds: 60,
  activeIdleCutoffSeconds: 60,
  partialRecoveryRate: 2,
};

assert.deepEqual(
  [0, 1799, 1800, 3599, 3600, 5399, 5400, 7199, 7200].map((x) => levelFor(x, config)),
  [0, 0, 1, 1, 2, 2, 3, 3, 4]
);
assert.equal(vitalityFor(0, config), 100);
assert.equal(vitalityFor(1800, config), 100);
assert.equal(vitalityFor(3600, config), 80);
assert.equal(vitalityFor(5400, config), 55);
assert.equal(vitalityFor(7200, config), 25);
assert.equal(vitalityFor(9000, config), 0);

const active = newState();
active.sedentarySeconds = 1799;
let result = stepHealth(active, 2, 0, false, config);
assert.equal(result.state.level, 1);
assert.equal(result.levelChanged, true);

const partial = newState();
partial.sedentarySeconds = 2400;
result = stepHealth(partial, 10, 90, false, config);
assert.equal(result.state.sedentarySeconds, 2380);
assert.equal(result.partialBreak, true);

const full = newState();
full.sedentarySeconds = 5000;
result = stepHealth(full, 1, 300, false, config);
assert.equal(result.fullBreak, false);
assert.equal(result.state.pendingFullBreak, true);
assert.equal(result.state.fullBreaks, 0);
result = stepHealth(full, 1, 0, false, config);
assert.equal(result.state.sedentarySeconds, 0);
assert.equal(result.state.vitality, 100);
assert.equal(result.fullBreak, true);
assert.equal(result.state.fullBreaks, 1);
assert.equal(result.fullBreakDurationSeconds, 300);
result = stepHealth(full, 1, 0, false, config);
assert.equal(result.fullBreak, false);
assert.equal(result.state.fullBreaks, 1);

const paused = newState();
paused.sedentarySeconds = 1000;
result = stepHealth(paused, 10, 0, true, config);
assert.equal(result.state.sedentarySeconds, 1000);
result = stepHealth(paused, 10, 300, true, config);
assert.equal(result.state.pendingFullBreak, false);

const sessions = newState("2026-07-14T00:00:00.000Z");
let transition = updateCodexSessions(sessions, "UserPromptSubmit", "a", "2026-07-14T00:00:01.000Z", 21600);
assert.equal(transition.becameRunning, true);
assert.equal(transition.activeCount, 1);
transition = updateCodexSessions(sessions, "PermissionRequest", "a", "2026-07-14T00:00:02.000Z", 21600);
assert.equal(transition.becameRunning, false);
assert.equal(transition.activeCount, 1);
transition = updateCodexSessions(sessions, "UserPromptSubmit", "b", "2026-07-14T00:00:03.000Z", 21600);
assert.equal(transition.activeCount, 2);
transition = updateCodexSessions(sessions, "Stop", "a", "2026-07-14T00:00:04.000Z", 21600);
assert.equal(transition.becameIdle, false);
assert.equal(transition.activeCount, 1);
transition = updateCodexSessions(sessions, "Stop", "b", "2026-07-14T00:00:05.000Z", 21600);
assert.equal(transition.becameIdle, true);
assert.equal(transition.activeCount, 0);

sessions.activeCodexSessions = [{ sessionHash: "stale", lastEventUtc: "2026-07-13T00:00:00.000Z" }];
transition = updateCodexSessions(sessions, "UserPromptSubmit", "fresh", "2026-07-14T00:00:00.000Z", 3600);
assert.equal(transition.activeCount, 1);
assert.equal(sessions.activeCodexSessions[0].sessionHash, "fresh");

console.log("health-core: ok");

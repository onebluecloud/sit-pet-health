"use strict";

function levelFor(sedentarySeconds, config) {
  if (sedentarySeconds < config.graceSeconds) return 0;
  if (sedentarySeconds < config.lazySeconds) return 1;
  if (sedentarySeconds < config.wiltedSeconds) return 2;
  if (sedentarySeconds < config.sickSeconds) return 3;
  return 4;
}

function vitalityFor(sedentarySeconds, config) {
  const anchors = [
    [0, config.graceSeconds, 100, 100],
    [config.graceSeconds, config.lazySeconds, 100, 80],
    [config.lazySeconds, config.wiltedSeconds, 80, 55],
    [config.wiltedSeconds, config.sickSeconds, 55, 25],
    [config.sickSeconds, config.sickSeconds + 1800, 25, 0],
  ];
  for (const [start, end, from, to] of anchors) {
    if (sedentarySeconds <= end) {
      if (end <= start) return Math.round(to * 10) / 10;
      const ratio = Math.max(0, Math.min(1, (sedentarySeconds - start) / (end - start)));
      return Math.round((from + (to - from) * ratio) * 10) / 10;
    }
  }
  return 0;
}

function newState(nowIso) {
  return {
    version: 2,
    sedentarySeconds: 0,
    vitality: 100,
    level: 0,
    fullBreakCreditedForIdleEpisode: false,
    pendingFullBreak: false,
    idleEpisodePeakSeconds: 0,
    lastBreakDurationSeconds: 0,
    fullBreaks: 0,
    listenedBreaks: 0,
    listenedStreak: 0,
    ignoredOpportunities: 0,
    codexStatus: "idle",
    activeCodexSessions: [],
    opportunityUntilUtc: null,
    opportunityPrompted: false,
    reminderHistoryUtc: [],
    healthReminderHistoryUtc: [],
    codexReminderHistoryUtc: [],
    lastLevelReminder: -1,
    updatedAtUtc: nowIso || new Date().toISOString(),
  };
}

function updateCodexSessions(state, eventName, sessionHash, nowValue, staleSeconds) {
  const now = nowValue instanceof Date ? nowValue : new Date(nowValue || Date.now());
  const cutoff = now.getTime() - Math.max(300, Number(staleSeconds || 21600)) * 1000;
  let sessions = Array.from(state.activeCodexSessions || []).filter((entry) => (
    entry && entry.sessionHash && Number.isFinite(Date.parse(entry.lastEventUtc)) && Date.parse(entry.lastEventUtc) > cutoff
  )).map((entry) => ({ sessionHash: String(entry.sessionHash), lastEventUtc: new Date(entry.lastEventUtc).toISOString() }));
  const wasRunning = sessions.length > 0;
  const key = String(sessionHash || "sessionless");
  if (eventName === "UserPromptSubmit" || eventName === "PermissionRequest") {
    sessions = sessions.filter((entry) => entry.sessionHash !== key);
    sessions.push({ sessionHash: key, lastEventUtc: now.toISOString() });
  } else if (eventName === "Stop") {
    sessions = sessions.filter((entry) => entry.sessionHash !== key);
  }
  state.activeCodexSessions = sessions;
  const isRunning = sessions.length > 0;
  state.codexStatus = isRunning ? "running" : "idle";
  return {
    state,
    wasRunning,
    isRunning,
    becameRunning: !wasRunning && isRunning,
    becameIdle: wasRunning && !isRunning,
    activeCount: sessions.length,
  };
}

function stepHealth(state, deltaSeconds, idleSeconds, isPaused, config) {
  const previousSedentarySeconds = state.sedentarySeconds;
  const previousLevel = state.level;
  let fullBreak = false;
  let partialBreak = false;
  let fullBreakDurationSeconds = 0;

  if (!isPaused && deltaSeconds > 0 && deltaSeconds <= 30) {
    if (idleSeconds >= config.fullBreakSeconds) {
      state.pendingFullBreak = true;
      state.idleEpisodePeakSeconds = Math.max(Number(state.idleEpisodePeakSeconds || 0), idleSeconds);
    } else if (idleSeconds >= config.partialBreakStartSeconds) {
      state.idleEpisodePeakSeconds = Math.max(Number(state.idleEpisodePeakSeconds || 0), idleSeconds);
      state.sedentarySeconds = Math.max(0, state.sedentarySeconds - deltaSeconds * config.partialRecoveryRate);
      partialBreak = true;
    } else if (idleSeconds < config.activeIdleCutoffSeconds) {
      if (state.pendingFullBreak) {
        state.sedentarySeconds = 0;
        state.pendingFullBreak = false;
        state.fullBreakCreditedForIdleEpisode = true;
        state.fullBreaks += 1;
        fullBreakDurationSeconds = Number(state.idleEpisodePeakSeconds || 0);
        state.lastBreakDurationSeconds = fullBreakDurationSeconds;
        state.idleEpisodePeakSeconds = 0;
        fullBreak = true;
      } else {
        state.sedentarySeconds += deltaSeconds;
        state.fullBreakCreditedForIdleEpisode = false;
        state.idleEpisodePeakSeconds = 0;
      }
    }
  }

  state.level = levelFor(state.sedentarySeconds, config);
  state.vitality = vitalityFor(state.sedentarySeconds, config);
  return {
    state,
    previousSedentarySeconds,
    previousLevel,
    levelChanged: state.level !== previousLevel,
    fullBreak,
    fullBreakDurationSeconds,
    partialBreak,
  };
}

const api = { levelFor, vitalityFor, newState, stepHealth, updateCodexSessions };
if (typeof module !== "undefined" && module.exports) module.exports = api;
if (typeof globalThis !== "undefined") globalThis.SitPetHealth = api;

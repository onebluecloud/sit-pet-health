ObjC.import("AppKit");
ObjC.import("CoreGraphics");
ObjC.import("Foundation");
ObjC.import("QuartzCore");

function run(argv) {
  const pluginRoot = standardPath(String(argv[0] || ""));
  const pluginData = standardPath(String(argv[1] || ""));
  if (!pluginRoot || !pluginData) throw new Error("Plugin root and data paths are required.");

  const fm = $.NSFileManager.defaultManager;
  const configPath = pluginData + "/config.json";
  const statePath = pluginData + "/health-state.json";
  const currentPet = readJson(pluginData + "/current-pet.json");
  const cloneDirectory = standardPath(String(currentPet.cloneDirectory));
  const profile = readJson(cloneDirectory + "/health-profile.json");
  const defaultConfig = readJson(pluginRoot + "/assets/default-config.json");
  const config = Object.assign(defaultConfig, isFile(configPath) ? safeReadJson(configPath, {}) : {});
  const dialogues = readJson(pluginRoot + "/assets/dialogues.zh-CN.json");
  const pausePath = pluginData + "/pause.flag";
  const eventRoot = pluginData + "/events";
  makeDirectory(eventRoot);
  if (!isFile(configPath)) writeJsonAtomic(configPath, config);

  let state = Object.assign(newState(), isFile(statePath) ? safeReadJson(statePath, {}) : {});
  state.version = 2;
  state.level = levelFor(Number(state.sedentarySeconds || 0), config);
  state.vitality = vitalityFor(Number(state.sedentarySeconds || 0), config);

  const app = $.NSApplication.sharedApplication;
  app.setActivationPolicy($.NSApplicationActivationPolicyAccessory);

  const atlases = {};
  for (let level = 0; level <= 4; level += 1) loadAtlas("stage-" + level, profile.stages[String(level)]);
  loadAtlas("celebrate", profile.celebrate);
  loadAtlas("held", profile.held);

  let scale = clamp(Number(config.petScale || 1), 0.30, 2.5);
  let currentAtlasName = "stage-" + state.level;
  let animationStarted = Date.now();
  let temporaryAtlasUntil = 0;
  let lastFrame = -1;
  let bubbleHideAt = 0;
  let lastTick = Date.now();
  let lastSave = Date.now();
  let lastCodexSeen = Date.now();
  let lastIdleSeconds = getIdleSeconds();

  const imageViewClassName = "SitPetImageView_" + String($.NSProcessInfo.processInfo.processIdentifier);
  ObjC.registerSubclass({
    name: imageViewClassName,
    superclass: "NSImageView",
    methods: {
      "mouseDown:": {
        types: ["void", ["id"]],
        implementation(event) {
          const before = this.window.frame.origin;
          setAtlas("held", 0);
          this.window.performWindowDragWithEvent(event);
          const after = this.window.frame.origin;
          const moved = Math.abs(Number(after.x) - Number(before.x)) + Math.abs(Number(after.y) - Number(before.y));
          clampWindow();
          if (moved < 3) {
            setAtlas("celebrate", Number(profile.celebrate.durationMs));
            showBubble(formatDialogue("click"), 4);
          } else {
            setAtlas("stage-" + state.level, 0);
            saveState();
          }
        },
      },
      "scrollWheel:": {
        types: ["void", ["id"]],
        implementation(event) {
          const delta = Number(event.scrollingDeltaY || event.deltaY || 0);
          applyScale(scale + (delta * 0.012), true);
        },
      },
      "magnifyWithEvent:": {
        types: ["void", ["id"]],
        implementation(event) {
          applyScale(scale * (1 + Number(event.magnification || 0)), true);
        },
      },
    },
  });

  const window = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(0, 0, 208 * scale, 224 * scale),
    $.NSWindowStyleMaskBorderless,
    $.NSBackingStoreBuffered,
    false
  );
  window.opaque = false;
  window.backgroundColor = $.NSColor.clearColor;
  window.hasShadow = false;
  window.level = $.NSFloatingWindowLevel;
  window.collectionBehavior = $.NSWindowCollectionBehaviorCanJoinAllSpaces | $.NSWindowCollectionBehaviorFullScreenAuxiliary;
  window.releasedWhenClosed = false;

  const imageViewClass = $[imageViewClassName];
  const imageView = imageViewClass.alloc.initWithFrame($.NSMakeRect(8 * scale, 8 * scale, 192 * scale, 208 * scale));
  imageView.imageScaling = $.NSImageScaleAxesIndependently;
  imageView.animates = false;
  imageView.wantsLayer = true;
  imageView.layer.magnificationFilter = "nearest";
  imageView.layer.minificationFilter = "nearest";
  window.contentView.addSubview(imageView);

  const bubbleWindow = $.NSPanel.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(0, 0, 316, 76),
    $.NSWindowStyleMaskBorderless,
    $.NSBackingStoreBuffered,
    false
  );
  bubbleWindow.opaque = false;
  bubbleWindow.backgroundColor = $.NSColor.clearColor;
  bubbleWindow.hasShadow = true;
  bubbleWindow.level = $.NSFloatingWindowLevel;
  bubbleWindow.ignoresMouseEvents = true;
  bubbleWindow.releasedWhenClosed = false;
  const bubbleCard = $.NSView.alloc.initWithFrame($.NSMakeRect(3, 3, 310, 70));
  bubbleCard.wantsLayer = true;
  bubbleCard.layer.backgroundColor = $.NSColor.colorWithCalibratedRedGreenBlueAlpha(1, 0.98, 0.95, 0.97).CGColor;
  bubbleCard.layer.borderColor = $.NSColor.colorWithCalibratedRedGreenBlueAlpha(0.9, 0.55, 0.43, 0.82).CGColor;
  bubbleCard.layer.borderWidth = 1;
  bubbleCard.layer.cornerRadius = 14;
  const bubbleLabel = $.NSTextField.alloc.initWithFrame($.NSMakeRect(14, 10, 282, 50));
  bubbleLabel.bezeled = false;
  bubbleLabel.drawsBackground = false;
  bubbleLabel.editable = false;
  bubbleLabel.selectable = false;
  bubbleLabel.textColor = $.NSColor.colorWithCalibratedRedGreenBlueAlpha(0.31, 0.27, 0.25, 1);
  bubbleLabel.font = $.NSFont.systemFontOfSize(14);
  bubbleLabel.lineBreakMode = $.NSLineBreakByWordWrapping;
  bubbleLabel.maximumNumberOfLines = 3;
  bubbleCard.addSubview(bubbleLabel);
  bubbleWindow.contentView.addSubview(bubbleCard);

  const delegateName = "SitPetMenuDelegate_" + String($.NSProcessInfo.processInfo.processIdentifier);
  ObjC.registerSubclass({
    name: delegateName,
    superclass: "NSObject",
    methods: {
      "togglePause:": {
        types: ["void", ["id"]],
        implementation() {
          if (isFile(pausePath)) {
            fm.removeItemAtPathError(pausePath, null);
            showBubble(String(dialogues.ui.resumed), 5);
          } else {
            writeText(pausePath, new Date().toISOString());
            showBubble(String(dialogues.ui.paused), 5);
          }
          updateMenu();
        },
      },
      "resetPosition:": {
        types: ["void", ["id"]],
        implementation() { moveToDefaultPosition(); saveState(); },
      },
      "resetScale:": {
        types: ["void", ["id"]],
        implementation() { applyScale(1, true); },
      },
      "exitRuntime:": {
        types: ["void", ["id"]],
        implementation() { app.terminate(null); },
      },
    },
  });
  const menuDelegate = $[delegateName].alloc.init;
  const menu = $.NSMenu.alloc.initWithTitle("RousePet");
  const statusItem = addMenuItem(menu, "", null, false);
  const statsItem = addMenuItem(menu, "", null, false);
  menu.addItem($.NSMenuItem.separatorItem);
  const pauseItem = addMenuItem(menu, String(dialogues.ui.pause), "togglePause:", true);
  addMenuItem(menu, String(dialogues.ui.resetPosition), "resetPosition:", true);
  addMenuItem(menu, String(dialogues.ui.resetScale), "resetScale:", true);
  menu.addItem($.NSMenuItem.separatorItem);
  addMenuItem(menu, String(dialogues.ui.exit), "exitRuntime:", true);
  imageView.menu = menu;

  applyScale(scale, false);
  if (config.windowX !== null && config.windowY !== null && Number.isFinite(Number(config.windowX)) && Number.isFinite(Number(config.windowY))) {
    window.setFrameOrigin($.NSMakePoint(Number(config.windowX), Number(config.windowY)));
  } else {
    moveToDefaultPosition();
  }
  clampWindow();
  updateMenu();
  setAtlas(currentAtlasName, 0);
  window.orderFrontRegardless;
  writeJsonAtomic(pluginData + "/runtime.pid", { pid: Number($.NSProcessInfo.processInfo.processIdentifier), startedAtUtc: new Date().toISOString() });
  log("Runtime starting for clone " + currentPet.cloneId + ".");

  if (!isFile(pluginData + "/welcome-shown.flag")) {
    showBubble(formatDialogue("welcome"), 8);
    writeText(pluginData + "/welcome-shown.flag", new Date().toISOString());
  }

  const animationBlock = ObjC.block("void", ["id"], function () {
    try {
      const now = Date.now();
      if (temporaryAtlasUntil && now >= temporaryAtlasUntil) setAtlas("stage-" + state.level, 0);
      const entry = atlases[currentAtlasName];
      const perFrame = Math.max(100, entry.durationMs / Math.max(1, entry.frames.length));
      const nextFrame = Math.floor((now - animationStarted) / perFrame) % Math.max(1, entry.frames.length);
      if (nextFrame !== lastFrame) {
        lastFrame = nextFrame;
        imageView.image = entry.frames[nextFrame];
      }
      if (bubbleHideAt && now >= bubbleHideAt) {
        bubbleHideAt = 0;
        bubbleWindow.orderOut(null);
      }
    } catch (error) { log("Animation error: " + error); }
  });
  const healthBlock = ObjC.block("void", ["id"], function () {
    try { healthTick(); } catch (error) { log("Tick error: " + error); }
  });
  const animationTimer = $.NSTimer.scheduledTimerWithTimeIntervalRepeatsBlock(0.09, true, animationBlock);
  const healthTimer = $.NSTimer.scheduledTimerWithTimeIntervalRepeatsBlock(Math.max(0.25, Number(config.pollMilliseconds) / 1000), true, healthBlock);

  app.run;
  animationTimer.invalidate;
  healthTimer.invalidate;
  saveState();
  bubbleWindow.orderOut(null);
  window.orderOut(null);
  fm.removeItemAtPathError(pluginData + "/runtime.pid", null);
  log("Runtime stopped.");
  return "";

  function healthTick() {
    const now = Date.now();
    const realDelta = (now - lastTick) / 1000;
    lastTick = now;
    lastIdleSeconds = getIdleSeconds();
    const paused = realDelta > 5 || screenIsLocked() || isFile(pausePath);
    processEvents();
    const effectiveConfig = Object.assign({}, config);
    if (state.opportunityPrompted) effectiveConfig.partialRecoveryRate = Number(config.partialRecoveryRate) * 2;
    const step = stepHealth(state, Math.min(30, realDelta), lastIdleSeconds, paused, effectiveConfig);
    state = step.state;
    if (step.fullBreak) {
      const listened = Boolean(state.opportunityPrompted);
      if (listened) {
        state.listenedBreaks = Number(state.listenedBreaks || 0) + 1;
        state.listenedStreak = Number(state.listenedStreak || 0) + 1;
        state.opportunityPrompted = false;
        state.opportunityUntilUtc = null;
      }
      setAtlas("celebrate", Number(profile.celebrate.durationMs) * 1.8);
      showBubble(formatDialogue(listened ? "listened" : "recovery"), 8);
    } else if (step.levelChanged) {
      setAtlas("stage-" + state.level, 0);
      if (state.level > step.previousLevel) {
        state.lastLevelReminder = state.level;
        showReminder("level" + state.level, state.level >= 3 ? 9 : 7);
      }
    }
    updateMenu();
    if (now - lastSave >= 15000) { saveState(); lastSave = now; }
    if (codexRunning()) lastCodexSeen = now;
    else if (now - lastCodexSeen >= 30000) app.terminate(null);
  }

  function processEvents() {
    const files = listDirectory(eventRoot).filter((name) => name.endsWith(".json")).sort();
    for (const name of files) {
      const path = eventRoot + "/" + name;
      try { processEvent(readJson(path)); } catch (error) { log("Ignored event " + name + ": " + error); }
      fm.removeItemAtPathError(path, null);
    }
  }
  function processEvent(event) {
    const name = String(event.eventName || "");
    const transition = updateCodexSessions(state, name, String(event.sessionHash || ""), new Date(), Number(config.codexSessionStaleSeconds));
    if (name === "UserPromptSubmit" || name === "PermissionRequest") {
      if (transition.becameRunning && state.sedentarySeconds >= Number(config.codexOpportunitySeconds) && lastIdleSeconds < Number(config.activeIdleCutoffSeconds)) {
        const key = state.listenedStreak > 0 ? "taskStartListened" : (state.ignoredOpportunities > 1 ? "taskStartIgnored" : "taskStartFirst");
        if (showReminder(key, 9, "codex")) {
          state.opportunityUntilUtc = new Date(Date.now() + Number(config.codexOpportunityWindowSeconds) * 1000).toISOString();
          state.opportunityPrompted = true;
        }
      }
    } else if (name === "Stop" && transition.becameIdle) {
      if (state.opportunityPrompted) {
        if (Date.parse(state.opportunityUntilUtc || "") > Date.now()) {
          state.ignoredOpportunities = Number(state.ignoredOpportunities || 0) + 1;
          state.listenedStreak = 0;
          showReminder("taskDone", 9, "codex");
        }
        state.opportunityPrompted = false;
        state.opportunityUntilUtc = null;
      }
    }
  }

  function loadAtlas(name, entry) {
    const source = $.NSImage.alloc.initWithContentsOfFile(cloneDirectory + "/" + String(entry.file));
    if (!source) throw new Error("Missing atlas " + entry.file);
    const frames = [];
    for (let frame = 0; frame < Number(entry.frames); frame += 1) {
      const output = $.NSImage.alloc.initWithSize($.NSMakeSize(192, 208));
      output.lockFocus;
      $.NSGraphicsContext.currentContext.imageInterpolation = $.NSImageInterpolationNone;
      source.drawInRectFromRectOperationFraction(
        $.NSMakeRect(0, 0, 192, 208),
        $.NSMakeRect(frame * 192, 0, 192, 208),
        $.NSCompositingOperationCopy,
        1
      );
      output.unlockFocus;
      frames.push(output);
    }
    atlases[name] = { frames, durationMs: Number(entry.durationMs) };
  }
  function setAtlas(name, durationMs) {
    if (!atlases[name]) return;
    currentAtlasName = name;
    animationStarted = Date.now();
    temporaryAtlasUntil = durationMs > 0 ? Date.now() + durationMs : 0;
    lastFrame = -1;
  }
  function applyScale(nextScale, persist) {
    scale = clamp(nextScale, 0.30, 2.5);
    const origin = window.frame.origin;
    window.setFrameDisplay($.NSMakeRect(Number(origin.x), Number(origin.y), 208 * scale, 224 * scale), true);
    imageView.frame = $.NSMakeRect(8 * scale, 8 * scale, 192 * scale, 208 * scale);
    clampWindow();
    if (persist) { config.petScale = Math.round(scale * 1000) / 1000; saveState(); }
  }
  function visibleFrame() { return $.NSScreen.mainScreen.visibleFrame; }
  function moveToDefaultPosition() {
    const frame = visibleFrame();
    window.setFrameOrigin($.NSMakePoint(Number(frame.origin.x + frame.size.width - window.frame.size.width - 22), Number(frame.origin.y + 22)));
  }
  function clampWindow() {
    const screen = window.screen || $.NSScreen.mainScreen;
    const frame = screen.visibleFrame;
    const width = Number(window.frame.size.width);
    const height = Number(window.frame.size.height);
    const x = clamp(Number(window.frame.origin.x), Number(frame.origin.x + 6), Number(frame.origin.x + frame.size.width - width - 6));
    const y = clamp(Number(window.frame.origin.y), Number(frame.origin.y + 6), Number(frame.origin.y + frame.size.height - height - 6));
    window.setFrameOrigin($.NSMakePoint(x, y));
  }
  function showBubble(text, seconds) {
    if (!text) return;
    bubbleLabel.stringValue = text;
    const petFrame = window.frame;
    const screen = (window.screen || $.NSScreen.mainScreen).visibleFrame;
    const width = Number(bubbleWindow.frame.size.width);
    const height = Number(bubbleWindow.frame.size.height);
    const x = clamp(Number(petFrame.origin.x + (petFrame.size.width - width) / 2), Number(screen.origin.x + 6), Number(screen.origin.x + screen.size.width - width - 6));
    let y = Number(petFrame.origin.y + petFrame.size.height + 7);
    if (y + height > Number(screen.origin.y + screen.size.height - 6)) y = Number(petFrame.origin.y - height - 7);
    bubbleWindow.setFrameOrigin($.NSMakePoint(x, y));
    bubbleWindow.alphaValue = 1;
    bubbleWindow.orderFrontRegardless;
    bubbleHideAt = Date.now() + Math.max(3, seconds) * 1000;
  }
  function formatDialogue(key) {
    const values = Array.from(dialogues[key] || []);
    if (!values.length) return "";
    const seed = (key + "|" + state.level + "|" + state.fullBreaks + "|" + state.listenedBreaks + "|" + new Date().getDate())
      .split("").reduce((total, character) => ((total * 31) + character.charCodeAt(0)) >>> 0, 7);
    return String(values[seed % values.length])
      .replace(/\{pet\}/g, String(currentPet.displayName))
      .replace(/\{minutes\}/g, String(Math.floor(Number(state.sedentarySeconds) / 60)));
  }
  function canRemind(kind) {
    const now = Date.now();
    const cutoff = Date.now() - 3600000;
    const property = kind === "codex" ? "codexReminderHistoryUtc" : "healthReminderHistoryUtc";
    const limit = kind === "codex" ? Number(config.codexRemindersPerHour) : Number(config.healthRemindersPerHour);
    state[property] = Array.from(state[property] || []).filter((value) => Date.parse(value) > cutoff);
    state.reminderHistoryUtc = Array.from(state.reminderHistoryUtc || []).filter((value) => Date.parse(value) > cutoff);
    if (state[property].length >= limit || state.reminderHistoryUtc.length >= Number(config.remindersPerHour)) return false;
    if (state.reminderHistoryUtc.length) {
      const latest = Math.max.apply(null, state.reminderHistoryUtc.map((value) => Date.parse(value)));
      if (now - latest < Number(config.reminderMinGapSeconds) * 1000) return false;
    }
    return true;
  }
  function showReminder(key, seconds, kind) {
    kind = kind || "health";
    if (!canRemind(kind)) return false;
    showBubble(formatDialogue(key), seconds);
    const property = kind === "codex" ? "codexReminderHistoryUtc" : "healthReminderHistoryUtc";
    const timestamp = new Date().toISOString();
    state[property].push(timestamp);
    state.reminderHistoryUtc.push(timestamp);
    return true;
  }
  function levelName() {
    return String(dialogues.ui[["healthy", "lazy", "wilted", "sick", "strike"][state.level]]);
  }
  function updateMenu() {
    statusItem.title = String(dialogues.ui.status) + ": " + levelName() + "  |  " + String(dialogues.ui.vitality) + " " + Math.round(Number(state.vitality)) + "  |  " + String(dialogues.ui.seated) + " " + Math.floor(Number(state.sedentarySeconds) / 60) + " " + String(dialogues.ui.minutes);
    statsItem.title = String(dialogues.ui.breaks) + " " + Number(state.fullBreaks || 0) + "  |  " + String(dialogues.ui.listened) + " " + Number(state.listenedBreaks || 0);
    pauseItem.title = isFile(pausePath) ? String(dialogues.ui.resume) : String(dialogues.ui.pause);
  }
  function addMenuItem(menuObject, title, selector, enabled) {
    const item = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent(title, selector || null, "");
    item.enabled = enabled;
    if (selector) item.target = menuDelegate;
    menuObject.addItem(item);
    return item;
  }
  function saveState() {
    state.updatedAtUtc = new Date().toISOString();
    config.windowX = Number(window.frame.origin.x);
    config.windowY = Number(window.frame.origin.y);
    config.petScale = scale;
    writeJsonAtomic(statePath, state);
    writeJsonAtomic(configPath, config);
  }
  function codexRunning() {
    const applications = $.NSWorkspace.sharedWorkspace.runningApplications.js;
    return applications.some((application) => {
      const name = String(unwrap(application.localizedName) || "").toLowerCase();
      const bundle = String(unwrap(application.bundleIdentifier) || "").toLowerCase();
      return name === "codex" || bundle.includes("openai.codex");
    });
  }
  function getIdleSeconds() {
    try { return Number($.CGEventSourceSecondsSinceLastEventType(0, -1)); }
    catch (_) { return 0; }
  }
  function screenIsLocked() {
    try {
      const dictionary = $.CGSessionCopyCurrentDictionary();
      if (!dictionary) return false;
      return Boolean(unwrap(dictionary.objectForKey("CGSSessionScreenIsLocked")));
    } catch (_) { return false; }
  }

  function levelFor(seconds, cfg) {
    if (seconds < Number(cfg.graceSeconds)) return 0;
    if (seconds < Number(cfg.lazySeconds)) return 1;
    if (seconds < Number(cfg.wiltedSeconds)) return 2;
    if (seconds < Number(cfg.sickSeconds)) return 3;
    return 4;
  }
  function vitalityFor(seconds, cfg) {
    const anchors = [
      [0, Number(cfg.graceSeconds), 100, 100],
      [Number(cfg.graceSeconds), Number(cfg.lazySeconds), 100, 80],
      [Number(cfg.lazySeconds), Number(cfg.wiltedSeconds), 80, 55],
      [Number(cfg.wiltedSeconds), Number(cfg.sickSeconds), 55, 25],
      [Number(cfg.sickSeconds), Number(cfg.sickSeconds) + 1800, 25, 0],
    ];
    for (const [start, end, from, to] of anchors) {
      if (seconds <= end) {
        const ratio = end <= start ? 1 : clamp((seconds - start) / (end - start), 0, 1);
        return Math.round((from + ((to - from) * ratio)) * 10) / 10;
      }
    }
    return 0;
  }
  function newState() {
    return {
      version: 2, sedentarySeconds: 0, vitality: 100, level: 0,
      fullBreakCreditedForIdleEpisode: false, pendingFullBreak: false,
      idleEpisodePeakSeconds: 0, lastBreakDurationSeconds: 0, fullBreaks: 0,
      listenedBreaks: 0, listenedStreak: 0, ignoredOpportunities: 0,
      codexStatus: "idle", activeCodexSessions: [], opportunityUntilUtc: null, opportunityPrompted: false,
      reminderHistoryUtc: [], healthReminderHistoryUtc: [], codexReminderHistoryUtc: [],
      lastLevelReminder: -1, updatedAtUtc: new Date().toISOString(),
    };
  }
  function updateCodexSessions(current, eventName, sessionHash, now, staleSeconds) {
    const cutoff = now.getTime() - Math.max(300, Number(staleSeconds || 21600)) * 1000;
    let sessions = Array.from(current.activeCodexSessions || []).filter((entry) => (
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
    current.activeCodexSessions = sessions;
    const isRunning = sessions.length > 0;
    current.codexStatus = isRunning ? "running" : "idle";
    return { wasRunning, isRunning, becameRunning: !wasRunning && isRunning, becameIdle: wasRunning && !isRunning, activeCount: sessions.length };
  }
  function stepHealth(current, delta, idle, paused, cfg) {
    const previousLevel = current.level;
    const previousSedentarySeconds = current.sedentarySeconds;
    let fullBreak = false;
    let fullBreakDurationSeconds = 0;
    if (!paused && delta > 0 && delta <= 30) {
      if (idle >= Number(cfg.fullBreakSeconds)) {
        current.pendingFullBreak = true;
        current.idleEpisodePeakSeconds = Math.max(Number(current.idleEpisodePeakSeconds || 0), idle);
      } else if (idle >= Number(cfg.partialBreakStartSeconds)) {
        current.idleEpisodePeakSeconds = Math.max(Number(current.idleEpisodePeakSeconds || 0), idle);
        current.sedentarySeconds = Math.max(0, Number(current.sedentarySeconds) - (delta * Number(cfg.partialRecoveryRate)));
      } else if (idle < Number(cfg.activeIdleCutoffSeconds)) {
        if (current.pendingFullBreak) {
          current.sedentarySeconds = 0;
          current.pendingFullBreak = false;
          current.fullBreakCreditedForIdleEpisode = true;
          current.fullBreaks = Number(current.fullBreaks || 0) + 1;
          fullBreakDurationSeconds = Number(current.idleEpisodePeakSeconds || 0);
          current.lastBreakDurationSeconds = fullBreakDurationSeconds;
          current.idleEpisodePeakSeconds = 0;
          fullBreak = true;
        } else {
          current.sedentarySeconds = Number(current.sedentarySeconds) + delta;
          current.fullBreakCreditedForIdleEpisode = false;
          current.idleEpisodePeakSeconds = 0;
        }
      }
    }
    current.level = levelFor(current.sedentarySeconds, cfg);
    current.vitality = vitalityFor(current.sedentarySeconds, cfg);
    return { state: current, previousLevel, previousSedentarySeconds, levelChanged: current.level !== previousLevel, fullBreak, fullBreakDurationSeconds };
  }
  function clamp(value, minimum, maximum) { return Math.max(minimum, Math.min(maximum, value)); }
  function standardPath(value) { return unwrap($(value).stringByExpandingTildeInPath.stringByStandardizingPath); }
  function unwrap(value) { try { return ObjC.unwrap(value); } catch (_) { return value; } }
  function isFile(path) {
    const isDirectory = Ref();
    return Boolean(fm.fileExistsAtPathIsDirectory(path, isDirectory)) && !Boolean(isDirectory[0]);
  }
  function makeDirectory(path) { fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(path, true, null, null); }
  function listDirectory(path) {
    const value = fm.contentsOfDirectoryAtPathError(path, null);
    return value ? value.js.map(unwrap) : [];
  }
  function readText(path) { return unwrap($.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null)); }
  function readJson(path) { return JSON.parse(readText(path)); }
  function safeReadJson(path, fallback) { try { return readJson(path); } catch (_) { return fallback; } }
  function writeText(path, text) { $(text).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null); }
  function writeJsonAtomic(path, value) {
    const temporary = path + "." + unwrap($.NSUUID.UUID.UUIDString) + ".tmp";
    writeText(temporary, JSON.stringify(value, null, 2) + "\n");
    if (isFile(path)) fm.removeItemAtPathError(path, null);
    if (!fm.moveItemAtPathToPathError(temporary, path, null)) throw new Error("Could not replace " + path);
  }
  function log(message) {
    try {
      const root = pluginData + "/logs";
      makeDirectory(root);
      const path = root + "/runtime.log";
      const line = "[" + new Date().toISOString() + "] " + message + "\n";
      const handle = isFile(path) ? $.NSFileHandle.fileHandleForWritingAtPath(path) : null;
      if (handle) {
        handle.seekToEndOfFile;
        handle.writeData($(line).dataUsingEncoding($.NSUTF8StringEncoding));
        handle.closeFile;
      } else writeText(path, line);
    } catch (_) {}
  }
}

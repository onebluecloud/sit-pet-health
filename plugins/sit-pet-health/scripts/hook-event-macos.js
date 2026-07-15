ObjC.import("Foundation");

function run(argv) {
  const pluginData = String(argv[0] || "");
  if (!pluginData) throw new Error("CLAUDE_PLUGIN_DATA is required.");
  const data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
  const text = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding)) || "{}";
  let payload = {};
  try { payload = JSON.parse(text); } catch (_) {}
  let eventName = String(payload.hook_event_name || payload.hookEventName || payload.event_name || payload.eventName || "SessionStart");
  const allowed = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop"];
  if (!allowed.includes(eventName)) eventName = "SessionStart";

  const fm = $.NSFileManager.defaultManager;
  const eventRoot = pluginData + "/events";
  fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(eventRoot, true, null, null);
  const stamp = String(Date.now()).padStart(13, "0");
  const uuid = ObjC.unwrap($.NSUUID.UUID.UUIDString).replace(/-/g, "").toLowerCase();
  const path = eventRoot + "/" + stamp + "-" + uuid + ".json";
  const body = JSON.stringify({ version: 1, eventName, occurredAtUtc: new Date().toISOString() }, null, 2) + "\n";
  if (!$(body).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)) {
    throw new Error("Could not write sanitized hook event.");
  }
  return eventName;
}

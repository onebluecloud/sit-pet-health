ObjC.import("AppKit");
ObjC.import("Foundation");

function run(argv) {
  const fm = $.NSFileManager.defaultManager;
  const pluginData = standardPath(String(argv[0] || ""));
  const requestedPet = String(argv[1] || "");
  let sourceDirectory = standardPath(String(argv[2] || ""));
  const pluginRoot = standardPath(String(argv[3] || ""));
  if (!pluginData) throw new Error("CLAUDE_PLUGIN_DATA is required.");
  if (!pluginRoot) throw new Error("Plugin root is required.");
  makeDirectory(pluginData);

  const selectionPath = pluginData + "/selected-source.json";
  if (!sourceDirectory && !requestedPet && isFile(selectionPath)) {
    try {
      const saved = readJson(selectionPath);
      const savedDirectory = standardPath(String(saved.sourceDirectory || ""));
      const customRoot = standardPath(pluginData + "/custom-sources") + "/";
      if (saved.sourceType === "custom" && savedDirectory.startsWith(customRoot) && isDirectory(savedDirectory)) {
        sourceDirectory = savedDirectory;
      }
    } catch (_) {}
  }

  let sourceType = "official";
  let sourceDirectories = [];
  if (sourceDirectory) {
    if (!isDirectory(sourceDirectory)) throw new Error("Custom pet directory not found: " + sourceDirectory);
    sourceType = "custom";
    sourceDirectories = [{ slug: sourceDirectory.split("/").pop(), directory: sourceDirectory }];
  } else {
    const environment = $.NSProcessInfo.processInfo.environment;
    const configuredHome = unwrap(environment.objectForKey("CODEX_HOME"));
    const codexHome = standardPath(configuredHome || (unwrap($.NSHomeDirectory()) + "/.codex"));
    const petsRoot = codexHome + "/pets";
    if (!isDirectory(petsRoot)) throw new Error("Codex pets directory not found: " + petsRoot);
    sourceDirectories = listDirectory(petsRoot).map((slug) => ({ slug, directory: standardPath(petsRoot + "/" + slug) }));
  }

  const candidates = [];
  for (const sourceEntry of sourceDirectories) {
    const slug = sourceEntry.slug;
    const directory = sourceEntry.directory;
    if (!isDirectory(directory)) continue;
    const manifestPath = directory + "/pet.json";
    if (!isFile(manifestPath)) continue;
    try {
      const manifest = readJson(manifestPath);
      if (manifest.sitPetHealthClone) continue;
      const relativeSprite = String(manifest.spritesheetPath || "spritesheet.webp");
      const spritePath = standardPath(directory + "/" + relativeSprite);
      if (!spritePath.startsWith(directory + "/")) continue;
      if (!isFile(spritePath) || !/\.(webp|png)$/i.test(spritePath)) continue;
      const size = fileSize(spritePath);
      if (size <= 0 || size > 20 * 1024 * 1024) continue;
      candidates.push({
        slug,
        directory,
        manifestPath,
        manifest,
        spritePath,
        modified: modificationSeconds(spritePath),
        sourceType,
      });
    } catch (_) {}
  }
  if (!candidates.length) throw new Error("No valid Codex pet was found. Run /hatch first.");

  let selected = null;
  if (requestedPet) {
    selected = candidates.find((item) =>
      item.slug === requestedPet ||
      String(item.manifest.id || "") === requestedPet ||
      String(item.manifest.displayName || "") === requestedPet
    );
    if (!selected) throw new Error("Pet not found: " + requestedPet);
  } else {
    if (isFile(selectionPath)) {
      try {
        const saved = readJson(selectionPath);
        selected = candidates.find((item) => item.slug === String(saved.slug || ""));
      } catch (_) {}
    }
    if (!selected) selected = candidates.sort((a, b) => b.modified - a.modified)[0];
  }

  const sourceHashBefore = sha256(selected.spritePath);
  const manifestHash = sha256(selected.manifestPath);
  const displayName = String(selected.manifest.displayName || selected.manifest.name || selected.slug);
  const safeSlug = selected.slug.toLowerCase().replace(/[^a-z0-9-]+/g, "-").replace(/^-|-$/g, "") || "pet";
  const cloneId = safeSlug + "-health-" + sourceHashBefore.slice(0, 8);
  const petsDataRoot = pluginData + "/pets";
  const cloneDirectory = petsDataRoot + "/" + cloneId;
  makeDirectory(petsDataRoot);

  if (cloneComplete(cloneDirectory, sourceHashBefore, manifestHash)) {
    if (sha256(selected.spritePath) !== sourceHashBefore || sha256(selected.manifestPath) !== manifestHash) {
      throw new Error("Source pet changed while the read-only clone was being checked.");
    }
    writeJsonAtomic(pluginData + "/selected-source.json", {
      slug: selected.slug,
      sourceType: selected.sourceType,
      sourceDirectory: selected.sourceType === "custom" ? selected.directory : null,
      sourceSpriteSha256: sourceHashBefore,
    });
    writeJsonAtomic(pluginData + "/current-pet.json", {
      version: 2,
      cloneId,
      cloneDirectory,
      sourceSlug: selected.slug,
      sourceType: selected.sourceType,
      sourceSpriteSha256: sourceHashBefore,
      displayName,
      candidateCount: candidates.length,
    });
    const enhancement = enhancementSummary(cloneDirectory);
    return JSON.stringify({
      ok: true,
      reused: true,
      cloneId,
      cloneDirectory,
      displayName,
      sourceSpriteSha256: sourceHashBefore,
      sourceManifestSha256: manifestHash,
      sourceUnchanged: true,
      candidateCount: candidates.length,
      enhancementRequired: enhancement.required,
      enhancementStatus: enhancement.status,
      enhancementActions: enhancement.actions,
      enhancementRequestPath: enhancement.requestPath,
    });
  }

  const staging = pluginData + "/staging/" + cloneId + "-" + unwrap($.NSUUID.UUID.UUIDString);
  makeDirectory(staging);

  try {
    const source = $.NSImage.alloc.initWithContentsOfFile(selected.spritePath);
    if (!source) throw new Error("macOS could not decode the pet spritesheet.");
    const rep = $.NSBitmapImageRep.imageRepWithContentsOfFile(selected.spritePath);
    if (!rep) throw new Error("macOS could not inspect the pet spritesheet.");
    const width = Number(rep.pixelsWide);
    const height = Number(rep.pixelsHigh);
    if (width !== 1536 || (height !== 1872 && height !== 2288)) {
      throw new Error("Unsupported spritesheet dimensions: " + width + "x" + height);
    }

    saveDrawnPng(source, width, height, [{
      destination: [0, 0, width, height],
      source: [0, 0, width, height],
    }], staging + "/spritesheet.png");

    const atlasRoot = staging + "/atlases";
    makeDirectory(atlasRoot);
    const catalog = readJson(pluginRoot + "/assets/action-layouts.json");
    const layout = Array.from(catalog.layouts || []).find((entry) => Number(entry.width) === width && Array.from(entry.heights || []).map(Number).indexOf(height) >= 0);
    if (!layout) throw new Error("No semantic action layout supports spritesheet dimensions " + width + "x" + height + ".");
    let actions = layout.actions || {};
    const fallbacks = layout.fallbacks || {};
    let actionLayoutId = String(layout.id || "unknown");
    let explicitHealthActions = [];
    if (selected.manifest.sitPetHealthActions) {
      const custom = selected.manifest.sitPetHealthActions;
      if (Number(custom.frameWidth) !== 192 || Number(custom.frameHeight) !== 208 || !custom.actions) {
        throw new Error("Custom semantic actions must provide 192x208 actions.");
      }
      actions = custom.actions;
      explicitHealthActions = ["tired", "sick", "rest"].filter((semantic) => Boolean(custom.actions[semantic]));
      actionLayoutId = String(custom.layoutId || "pet-manifest-custom");
    }
    function resolveAction(semantic) {
      const candidates = [semantic].concat(Array.from(fallbacks[semantic] || []));
      for (const candidate of candidates) {
        if (actions[candidate]) return { requested: semantic, resolved: candidate, action: actions[candidate] };
      }
      throw new Error("No semantic action or fallback is available for '" + semantic + "'.");
    }
    const definitions = [
      ["stage-0.png", "idle"], ["stage-1.png", "waiting"], ["stage-2.png", "tired"],
      ["stage-3.png", "sick"], ["stage-4.png", "rest"], ["celebrate.png", "celebrate"], ["held.png", "held"],
    ];
    const rowCount = Math.floor(height / 208);
    const columnCount = Math.floor(width / 192);
    const specs = definitions.map(([name, semantic]) => {
      const resolved = resolveAction(semantic);
      const action = resolved.action;
      const columns = Array.from(action.columns || []).map(Number);
      if (Number(action.row) < 0 || Number(action.row) >= rowCount || !columns.length || columns.length > 8 ||
          columns.some((column) => column < 0 || column >= columnCount) || Number(action.frames) < 1 || Number(action.frames) > 8) {
        throw new Error("Semantic action '" + resolved.resolved + "' has invalid coordinates.");
      }
      return { name, semantic, resolvedSemantic: resolved.resolved, row: Number(action.row), columns, frames: Number(action.frames), durationMs: Number(action.durationMs) };
    });
    for (const spec of specs) {
      const operations = spec.columns.map((column, destinationColumn) => ({
        destination: [destinationColumn * 192, 0, 192, 208],
        source: [column * 192, height - ((spec.row + 1) * 208), 192, 208],
      }));
      saveDrawnPng(source, 1536, 208, operations, atlasRoot + "/" + spec.name);
    }

    copyFile(selected.manifestPath, staging + "/source-pet.json");
    const extension = selected.spritePath.toLowerCase().endsWith(".png") ? ".png" : ".webp";
    copyFile(selected.spritePath, staging + "/source-spritesheet" + extension);

    writeJsonAtomic(staging + "/pet.json", {
      id: cloneId,
      displayName: displayName + " · RousePet",
      description: "A private RousePet copy of " + displayName + ". The source pet remains read-only.",
      spriteVersionNumber: height === 2288 ? 2 : 1,
      spritesheetPath: "spritesheet.png",
      sitPetHealthClone: { version: 1, sourceSlug: selected.slug, sourceSpriteSha256: sourceHashBefore },
    });
    const stages = {};
    for (let level = 0; level <= 4; level += 1) {
      stages[String(level)] = {
        file: "atlases/" + specs[level].name,
        semanticAction: specs[level].resolvedSemantic,
        frames: specs[level].frames,
        durationMs: specs[level].durationMs,
      };
    }
    const enhancementActions = [
      { semantic: "tired", stage: 2 },
      { semantic: "sick", stage: 3 },
      { semantic: "rest", stage: 4 },
    ].filter((item) => explicitHealthActions.indexOf(item.semantic) < 0).map((item) => ({
      semantic: item.semantic,
      stage: item.stage,
      reason: "No explicit dedicated health action is declared by this pet.",
      currentSemantic: specs[item.stage].resolvedSemantic,
      currentFile: "atlases/" + specs[item.stage].name,
    }));
    writeJsonAtomic(staging + "/health-profile.json", {
      version: 3,
      actionLayoutId,
      sourceSlug: selected.slug,
      sourceDisplayName: displayName,
      sourceSpriteSha256: sourceHashBefore,
      sourceManifestSha256: manifestHash,
      sourceWidth: width,
      sourceHeight: height,
      frameWidth: 192,
      frameHeight: 208,
      stages,
      celebrate: { file: "atlases/celebrate.png", semanticAction: specs[5].resolvedSemantic, frames: specs[5].frames, durationMs: specs[5].durationMs },
      held: { file: "atlases/held.png", semanticAction: specs[6].resolvedSemantic, frames: specs[6].frames, durationMs: specs[6].durationMs },
      healthExtension: {
        version: 1,
        status: enhancementActions.length ? "required" : "complete",
        actions: enhancementActions,
        policy: "Generate only missing dedicated health actions in the private RousePet clone.",
      },
      generatedAtUtc: new Date().toISOString(),
    });

    if (sha256(selected.spritePath) !== sourceHashBefore) {
      throw new Error("Source pet changed while the read-only clone was being created.");
    }
    if (sha256(selected.manifestPath) !== manifestHash) {
      throw new Error("Source pet manifest changed while the read-only clone was being created.");
    }
    if (!cloneComplete(cloneDirectory, sourceHashBefore, manifestHash)) {
      if (isDirectory(cloneDirectory)) removeItem(cloneDirectory);
      moveItem(staging, cloneDirectory);
    }
    else removeItem(staging);

    writeJsonAtomic(pluginData + "/selected-source.json", {
      slug: selected.slug,
      sourceType: selected.sourceType,
      sourceDirectory: selected.sourceType === "custom" ? selected.directory : null,
      sourceSpriteSha256: sourceHashBefore,
    });
    writeJsonAtomic(pluginData + "/current-pet.json", {
      version: 2,
      cloneId,
      cloneDirectory,
      sourceSlug: selected.slug,
      sourceType: selected.sourceType,
      sourceSpriteSha256: sourceHashBefore,
      displayName,
      candidateCount: candidates.length,
    });
    const enhancement = enhancementSummary(cloneDirectory);
    return JSON.stringify({
      ok: true,
      reused: false,
      cloneId,
      cloneDirectory,
      displayName,
      sourceSpriteSha256: sourceHashBefore,
      sourceManifestSha256: manifestHash,
      sourceUnchanged: true,
      candidateCount: candidates.length,
      enhancementRequired: enhancement.required,
      enhancementStatus: enhancement.status,
      enhancementActions: enhancement.actions,
      enhancementRequestPath: enhancement.requestPath,
    });
  } catch (error) {
    if (isDirectory(staging)) removeItem(staging);
    throw error;
  }

  function unwrap(value) {
    if (value === null || value === undefined) return null;
    try { return ObjC.unwrap(value); } catch (_) { return value; }
  }
  function standardPath(value) {
    if (!value) return "";
    return unwrap($(value).stringByExpandingTildeInPath.stringByStandardizingPath.stringByResolvingSymlinksInPath);
  }
  function isFile(path) {
    const isDir = Ref();
    return Boolean(fm.fileExistsAtPathIsDirectory(path, isDir)) && !Boolean(isDir[0]);
  }
  function isDirectory(path) {
    const isDir = Ref();
    return Boolean(fm.fileExistsAtPathIsDirectory(path, isDir)) && Boolean(isDir[0]);
  }
  function makeDirectory(path) {
    const error = Ref();
    if (!fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(path, true, null, error) && !isDirectory(path)) {
      throw new Error("Could not create directory: " + path);
    }
  }
  function listDirectory(path) {
    const result = fm.contentsOfDirectoryAtPathError(path, null);
    return result ? result.js.map(unwrap) : [];
  }
  function fileSize(path) {
    const attributes = fm.attributesOfItemAtPathError(path, null);
    return Number(unwrap(attributes.objectForKey($.NSFileSize)) || 0);
  }
  function modificationSeconds(path) {
    const attributes = fm.attributesOfItemAtPathError(path, null);
    return Number(attributes.objectForKey($.NSFileModificationDate).timeIntervalSince1970 || 0);
  }
  function readText(path) {
    return unwrap($.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null));
  }
  function readJson(path) { return JSON.parse(readText(path)); }
  function writeJsonAtomic(path, value) {
    const temporary = path + "." + unwrap($.NSUUID.UUID.UUIDString) + ".tmp";
    const text = JSON.stringify(value, null, 2) + "\n";
    if (!$(text).writeToFileAtomicallyEncodingError(temporary, true, $.NSUTF8StringEncoding, null)) {
      throw new Error("Could not write " + path);
    }
    if (isFile(path)) fm.removeItemAtPathError(path, null);
    if (!fm.moveItemAtPathToPathError(temporary, path, null)) throw new Error("Could not replace " + path);
  }
  function copyFile(from, to) {
    if (!fm.copyItemAtPathToPathError(from, to, null)) throw new Error("Could not copy " + from);
  }
  function moveItem(from, to) {
    if (!fm.moveItemAtPathToPathError(from, to, null)) throw new Error("Could not move " + from);
  }
  function removeItem(path) { fm.removeItemAtPathError(path, null); }
  function cloneComplete(path, spriteHash, manifestHash) {
    try {
      const required = [path + "/health-profile.json", path + "/pet.json", path + "/spritesheet.png"]
        .concat(["stage-0.png", "stage-1.png", "stage-2.png", "stage-3.png", "stage-4.png", "celebrate.png", "held.png"]
          .map((name) => path + "/atlases/" + name));
      if (!required.every((file) => isFile(file) && fileSize(file) > 0)) return false;
      const profile = readJson(path + "/health-profile.json");
      return Number(profile.version || 0) >= 3 && String(profile.actionLayoutId || "") &&
        String(profile.sourceSpriteSha256 || "") === spriteHash &&
        String(profile.sourceManifestSha256 || "") === manifestHash;
    } catch (_) {
      return false;
    }
  }
  function enhancementSummary(path) {
    const profile = readJson(path + "/health-profile.json");
    const extension = profile.healthExtension || {};
    const status = String(extension.status || "required");
    const actions = Array.from(extension.actions || []).map((item) => String(item.semantic || "")).filter(Boolean);
    return {
      required: status !== "complete",
      status,
      actions,
      requestPath: path + "/health-profile.json",
    };
  }
  function sha256(path) {
    const task = $.NSTask.alloc.init;
    const pipe = $.NSPipe.pipe;
    task.launchPath = "/usr/bin/shasum";
    task.arguments = ["-a", "256", path];
    task.standardOutput = pipe;
    task.standardError = $.NSPipe.pipe;
    task.launch;
    task.waitUntilExit;
    if (Number(task.terminationStatus) !== 0) throw new Error("Could not hash " + path);
    const data = pipe.fileHandleForReading.readDataToEndOfFile;
    const output = unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding));
    return output.trim().split(/\s+/)[0].toLowerCase();
  }
  function saveDrawnPng(source, width, height, operations, path) {
    const bitmap = $.NSBitmapImageRep.alloc.initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(
      null, width, height, 8, 4, true, false, $.NSDeviceRGBColorSpace, 0, 32
    );
    const context = $.NSGraphicsContext.graphicsContextWithBitmapImageRep(bitmap);
    $.NSGraphicsContext.saveGraphicsState;
    $.NSGraphicsContext.currentContext = context;
    context.imageInterpolation = $.NSImageInterpolationNone;
    for (const operation of operations) {
      const d = operation.destination;
      const s = operation.source;
      source.drawInRectFromRectOperationFraction(
        $.NSMakeRect(d[0], d[1], d[2], d[3]),
        $.NSMakeRect(s[0], s[1], s[2], s[3]),
        $.NSCompositingOperationCopy,
        1.0
      );
    }
    $.NSGraphicsContext.restoreGraphicsState;
    const data = bitmap.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, {});
    if (!data.writeToFileAtomically(path, true)) throw new Error("Could not save " + path);
  }
}

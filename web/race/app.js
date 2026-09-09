(() => {
  "use strict";

  const body = document.getElementById("race-ui");
  const $ = id => document.getElementById("race-" + id);
  let state = { phase: "waiting", rows: [], courses: [] };
  let activeTab = "lobby";
  let courseSignature = "";
  let editorSignature = "";
  let pulseTimer = 0;
  let goTimer = 0;
  let goActive = false;
  let countdownVisualToken = "";
  let guideAngle = 0;
  let guideAngleReady = false;

  const phaseNames = {
    waiting: "LOBBY",
    forming: "FORMING GRID",
    grid: "DRIVERS TO CARS",
    countdown: "COUNTDOWN",
    active: "RACING",
    results: "RESULTS"
  };

  function number(value, fallback = 0) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : fallback;
  }

  function integer(value, fallback = 0) {
    return Math.trunc(number(value, fallback));
  }

  function raceTime(milliseconds, short = false) {
    const value = Math.max(0, number(milliseconds));
    const totalSeconds = Math.floor(value / 1000);
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;
    const millis = Math.floor(value % 1000);
    if (short) return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
    return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}.${String(millis).padStart(3, "0")}`;
  }

  function selfRow() {
    return (Array.isArray(state.rows) ? state.rows : []).find(row =>
      String(row.id) === String(state.playerId));
  }

  function statusLabel(row) {
    const status = String(row.state || "").toLowerCase();
    if (status === "finished") return row.finishMs != null ? raceTime(row.finishMs) : "FINISH";
    if (status === "dnf" || status === "disconnected") return "DNF";
    if (status === "countdown") return "GRID";
    if (status === "grid") return "BOARDING";
    if (status === "racing") return "RACING";
    return status.toUpperCase() || "--";
  }

  function setTab(name) {
    if (name === "editor" && !(state.editor && state.editor.open !== false)) name = "lobby";
    activeTab = name;
    body.querySelectorAll(".tab").forEach(button =>
      button.classList.toggle("active", button.dataset.tab === name));
    body.querySelectorAll(".tab-page").forEach(page =>
      page.classList.toggle("active", page.dataset.page === name));
  }

  function renderLiveRows() {
    const container = $("liveRows");
    container.replaceChildren();
    const all = Array.isArray(state.rows) ? state.rows : [];
    const ownIndex = all.findIndex(row => String(row.id) === String(state.playerId));
    // Keep the leader and the player's immediate rivals visible even in P32.
    const rows = ownIndex < 6 ? all.slice(0, 6) :
      [...all.slice(0, 2), ...all.slice(Math.min(ownIndex - 1, all.length - 4),
        Math.min(ownIndex - 1, all.length - 4) + 4)];
    for (const row of rows) {
      const item = document.createElement("div");
      item.className = "live-row";
      if (String(row.id) === String(state.playerId)) item.classList.add("self");
      if (integer(row.rank) === 1) item.classList.add("leader");
      const rank = document.createElement("span");
      rank.textContent = `P${integer(row.rank, 0) || "-"}`;
      const driver = document.createElement("b");
      driver.textContent = String(row.name || "Driver").slice(0, 48);
      const progress = document.createElement("em");
      progress.textContent = row.state === "finished" ? raceTime(row.finishMs) :
        row.state === "dnf" || row.state === "disconnected" ? "DNF" :
        `L${integer(row.lap, 1)} · ${Math.min(integer(row.checkpointIndex, 1), integer(row.totalCheckpoints, 1))}/${integer(row.totalCheckpoints, 1)}`;
      item.append(rank, driver, progress);
      container.append(item);
    }
  }

  function renderBoard() {
    const container = $("boardRows");
    container.replaceChildren();
    const rows = Array.isArray(state.rows) ? state.rows : [];
    for (const row of rows) {
      const item = document.createElement("div");
      item.className = "board-row";
      if (String(row.id) === String(state.playerId)) item.classList.add("self");
      if (integer(row.rank) === 1) item.classList.add("leader");
      if (["dnf", "disconnected"].includes(String(row.state))) item.classList.add("dnf");
      const values = [
        `P${integer(row.rank, 0) || "-"}`,
        String(row.name || "Driver").slice(0, 48),
        statusLabel(row),
        `${integer(row.lap, 1)}/${integer(row.laps, 1)}`,
        `${Math.min(integer(row.checkpointIndex, 1), integer(row.totalCheckpoints, 1))}/${integer(row.totalCheckpoints, 1)}`,
        row.finishMs != null ? raceTime(row.finishMs) : "--:--.---",
        row.bestLapMs != null ? raceTime(row.bestLapMs) : "--:--.---"
      ];
      values.forEach((value, index) => {
        const cell = document.createElement("span");
        cell.textContent = value;
        if (index === 1) cell.className = "driver";
        if (index === 2) cell.className = "status";
        item.append(cell);
      });
      container.append(item);
    }
    $("boardEmpty").classList.toggle("hidden", rows.length > 0);
  }

  function renderCourses(courses) {
    const signature = JSON.stringify((courses || []).map(course => [
      course.id, course.name, course.type, course.laps, course.checkpointCount,
      course.gridCount, course.gridCapacity, course.vehicle, course.vehicleLabel,
      course.selected, course.revision
    ]));
    if (signature === courseSignature) return;
    courseSignature = signature;
    const container = $("courseList");
    container.replaceChildren();
    for (const course of courses || []) {
      const card = document.createElement("article");
      card.className = "course-card" + (course.selected ? " selected" : "");
      const name = document.createElement("b");
      name.textContent = String(course.name || course.id || "Course").slice(0, 64);
      const specs = document.createElement("em");
      specs.textContent = `${String(course.type || "circuit").toUpperCase()} · ${integer(course.laps, 1)}L · ${integer(course.checkpointCount)}CP · ${integer(course.gridCapacity)} GRID · ${String(course.vehicleLabel || "CAR").toUpperCase()}`;
      const description = document.createElement("p");
      description.textContent = String(course.description || "No description.").slice(0, 240);
      card.append(name, specs, description);
      container.append(card);
    }
  }

  function coordinate(point) {
    const p = point && point.position;
    if (!p) return "Not captured";
    return `${number(p.x).toFixed(1)}, ${number(p.y).toFixed(1)}, ${number(p.z).toFixed(1)} · ${number(point.heading).toFixed(0)}°`;
  }

  function editorKey(editor, action, fallback) {
    const keys = editor && editor.keys && typeof editor.keys === "object" ? editor.keys : {};
    return String(keys[action] || fallback).slice(0, 12).toUpperCase();
  }

  const editorErrorCopy = {
    position_unavailable: "Server position is not available yet. Wait a moment and retry.",
    editor_world_required: "Return to the editor world before capturing this point.",
    grid_slots_overlap: "This grid slot overlaps another one. Move the car farther away.",
    too_many_grid_slots: "The course already has the maximum number of grid slots.",
    too_many_checkpoints: "The course already has the maximum number of checkpoints.",
    invalid_grid_index: "That grid slot no longer exists.",
    invalid_checkpoint_index: "That checkpoint no longer exists.",
    start_missing: "Capture a start position before saving.",
    grid_missing: "Capture at least one vehicle grid slot before saving.",
    not_enough_grid_slots: "Capture at least one vehicle grid slot before saving.",
    not_enough_checkpoints: "Capture the required checkpoint(s) before saving.",
    name_too_short: "The course name must contain at least three characters.",
    invalid_type: "Choose either Circuit or Sprint.",
    invalid_laps: "The lap count is outside the supported range.",
    invalid_vehicle: "Choose one of the race vehicles allowed by the server.",
    invalid_checkpoint_radius: "The checkpoint radius must be between 2 and 30 metres.",
    builtin_readonly: "Built-in courses are read-only. Load one to create an editable copy.",
    course_not_found: "That course no longer exists.",
    heat_in_progress: "Wait for the active heat to finish before selecting another course.",
    session_expired: "The editor session expired. Run /race.editor again.",
    unknown_action: "The server did not recognise that editor action."
  };

  function readableEditorError(error) {
    const raw = String(error || "");
    const code = raw.split(":", 1)[0];
    if (editorErrorCopy[code]) return editorErrorCopy[code];
    if (code === "vehicle_spawn_failed") return "The editor car could not be created. Retry with the CAR key.";
    if (code === "storage_write_failed" || code === "storage_delete_failed")
      return "The course JSON could not be written. Check the server storage log.";
    return raw.replaceAll("_", " ");
  }

  function editorNextStep(draft, grid, checkpoints, vehicleReady) {
    if (!vehicleReady) return "Creating the editor car…";
    if (!(draft.start && draft.start.position)) return "Next: drive to the start and capture it.";
    if (!grid.length) return "Next: capture at least one exact vehicle grid slot.";
    const required = draft.type === "sprint" ? 1 : 2;
    if (checkpoints.length < required)
      return `Next: capture ${required - checkpoints.length} more checkpoint${required - checkpoints.length === 1 ? "" : "s"}.`;
    return "Course geometry is ready. Open options if needed, then save.";
  }

  function emitEditor(action, extra = {}) {
    Open77.emit("race:editor", { action, ...extra });
  }

  function closeCustomDropdowns(except = null) {
    body.querySelectorAll(".custom-dropdown.open").forEach(dropdown => {
      if (dropdown === except) return;
      dropdown.classList.remove("open");
      const trigger = dropdown.querySelector(".custom-dropdown-trigger");
      if (trigger) trigger.setAttribute("aria-expanded", "false");
    });
  }

  function dropdownValue(id) {
    return String($(id).dataset.value || "");
  }

  function selectDropdownValue(dropdown, value, notify = false) {
    const options = Array.from(dropdown.querySelectorAll(".custom-dropdown-option"));
    const selected = options.find(option => option.dataset.value === String(value)) || options[0];
    if (!selected) return;
    const previous = String(dropdown.dataset.value || "");
    dropdown.dataset.value = String(selected.dataset.value || "");
    const trigger = dropdown.querySelector(".custom-dropdown-trigger");
    const label = dropdown.querySelector(".custom-dropdown-value");
    label.textContent = selected.textContent;
    trigger.title = selected.textContent;
    options.forEach(option => {
      const active = option === selected;
      option.classList.toggle("selected", active);
      option.setAttribute("aria-selected", active ? "true" : "false");
    });
    if (dropdown.id === "editType")
      $("editLaps").disabled = dropdown.dataset.value === "sprint";
    if (notify && previous !== dropdown.dataset.value) syncFields();
  }

  function setDropdownOptions(id, options, value) {
    const dropdown = $(id);
    const menu = dropdown.querySelector(".custom-dropdown-menu");
    const trigger = dropdown.querySelector(".custom-dropdown-trigger");
    menu.replaceChildren();
    dropdown.classList.remove("empty");
    trigger.disabled = options.length === 0;
    if (!options.length) {
      dropdown.classList.add("empty");
      dropdown.dataset.value = "";
      dropdown.querySelector(".custom-dropdown-value").textContent = "NO OPTIONS AVAILABLE";
      trigger.title = "No options available";
      closeCustomDropdowns();
      return;
    }
    options.forEach((entry, index) => {
      const option = document.createElement("button");
      option.type = "button";
      option.className = "custom-dropdown-option";
      option.id = `${id}Option${index}`;
      option.dataset.value = String(entry.value ?? "");
      option.setAttribute("role", "option");
      option.textContent = String(entry.label || entry.value || "OPTION").slice(0, 64);
      option.addEventListener("click", event => {
        event.stopPropagation();
        selectDropdownValue(dropdown, option.dataset.value, true);
        closeCustomDropdowns();
        dropdown.querySelector(".custom-dropdown-trigger").focus();
      });
      menu.append(option);
    });
    selectDropdownValue(dropdown, value);
  }

  function initializeCustomDropdowns() {
    body.querySelectorAll(".custom-dropdown").forEach(dropdown => {
      const trigger = dropdown.querySelector(".custom-dropdown-trigger");
      trigger.addEventListener("click", event => {
        event.stopPropagation();
        if (trigger.disabled) return;
        const opening = !dropdown.classList.contains("open");
        closeCustomDropdowns(dropdown);
        dropdown.classList.toggle("open", opening);
        trigger.setAttribute("aria-expanded", opening ? "true" : "false");
        if (opening) {
          const selected = dropdown.querySelector(".custom-dropdown-option.selected") ||
            dropdown.querySelector(".custom-dropdown-option");
          if (selected) selected.focus();
        }
      });
      dropdown.addEventListener("keydown", event => {
        const options = Array.from(dropdown.querySelectorAll(".custom-dropdown-option"));
        if (!options.length) return;
        const current = options.indexOf(document.activeElement);
        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
          event.preventDefault();
          if (!dropdown.classList.contains("open")) {
            closeCustomDropdowns(dropdown);
            dropdown.classList.add("open");
            trigger.setAttribute("aria-expanded", "true");
          }
          const direction = event.key === "ArrowDown" ? 1 : -1;
          const fallback = direction > 0 ? -1 : 0;
          options[((current < 0 ? fallback : current) + direction + options.length) % options.length].focus();
        } else if (event.key === "Home" || event.key === "End") {
          event.preventDefault();
          options[event.key === "Home" ? 0 : options.length - 1].focus();
        } else if (event.key === "Escape" && state.panelOpen) {
          event.preventDefault();
          event.stopPropagation();
          closeCustomDropdowns();
          trigger.focus();
        } else if (event.key === "Tab") {
          closeCustomDropdowns();
        }
      });
    });
    document.addEventListener("click", () => closeCustomDropdowns());
  }

  function renderEditor(editor) {
    const enabled = editor && editor.open !== false;
    $("editorTab").classList.toggle("hidden", !enabled);
    if (!enabled) {
      if (activeTab === "editor") setTab("lobby");
      editorSignature = "";
      return;
    }
    const draft = editor.draft || {};
    const checkpoints = Array.isArray(draft.checkpoints) ? draft.checkpoints : [];
    const grid = Array.isArray(draft.grid) ? draft.grid : [];
    const vehicles = Array.isArray(editor.vehicles) ? editor.vehicles : [];
    const signature = JSON.stringify([
      draft.id, draft.name, draft.description, draft.type, draft.laps,
      draft.checkpointRadius, draft.vehicle, coordinate(draft.start),
      grid.map(coordinate), checkpoints.map(coordinate), vehicles,
      editor.message, editor.error, editor.vehicleId,
      editor.keys,
      (editor.courses || []).map(course => [
        course.id, course.name, course.vehicle, course.vehicleLabel,
        course.selected, course.revision])
    ]);
    if (signature === editorSignature) return;
    editorSignature = signature;

    $("editName").value = String(draft.name || "").slice(0, 64);
    $("editDescription").value = String(draft.description || "").slice(0, 240);
    setDropdownOptions("editVehicle", vehicles.map(vehicle => ({
      value: String(vehicle.id || ""),
      label: String(vehicle.label || vehicle.id || "Vehicle")
    })), String(draft.vehicle || (vehicles[0] && vehicles[0].id) || ""));
    setDropdownOptions("editType", [
      { value: "circuit", label: "Circuit / multilap" },
      { value: "sprint", label: "Start -> finish" }
    ], draft.type === "sprint" ? "sprint" : "circuit");
    $("editLaps").value = String(integer(draft.laps, 1));
    $("editLaps").disabled = dropdownValue("editType") === "sprint";
    $("editRadius").value = String(number(draft.checkpointRadius, 7));
    $("startState").textContent = coordinate(draft.start);
    $("gridCount").textContent = `${grid.length} SLOT${grid.length === 1 ? "" : "S"}`;
    $("checkpointCount").textContent = String(checkpoints.length);
    const status = $("editorStatus");
    status.classList.toggle("error", Boolean(editor.error));
    const nextStep = editorNextStep(draft, grid, checkpoints, Boolean(editor.vehicleId));
    const editorStatusCopy = editor.error ? readableEditorError(editor.error) :
      [editor.message, nextStep].filter(Boolean).join(" · ");
    status.textContent = String(editorStatusCopy ||
      (editor.storage && editor.storage.ready
        ? `JSON storage ready · ${String(editor.storage.directory || "data/courses")}`
        : `JSON storage unavailable · ${String(editor.storage && editor.storage.error || "unknown error")}`)).slice(0, 180);

    $("editorDriveHud").classList.toggle("error", Boolean(editor.error));
    $("driveCourseName").textContent = String(draft.name || "New Night City Race").slice(0, 48);
    $("driveStartCount").textContent = draft.start && draft.start.position ? "1 / 1" : "0 / 1";
    $("driveGridCount").textContent = String(grid.length);
    $("driveCheckpointCount").textContent = String(checkpoints.length);
    $("driveStatus").textContent = String(editorStatusCopy || nextStep).slice(0, 150);
    $("keyVehicle").textContent = editorKey(editor, "spawnVehicle", "F4");
    $("keyMenu").textContent = editorKey(editor, "menu", "F5");
    $("keyCaptureStart").textContent = editorKey(editor, "captureStart", "F6");
    $("keyCaptureGrid").textContent = editorKey(editor, "captureGrid", "F7");
    $("keyCaptureCheckpoint").textContent = editorKey(editor, "addCheckpoint", "F8");
    $("keyUndoCheckpoint").textContent = editorKey(editor, "undo", "F9");
    $("keyUndoGrid").textContent = editorKey(editor, "undoGrid", "F10");
    $("keySave").textContent = editorKey(editor, "save", "F11");
    $("keyExit").textContent = editorKey(editor, "close", "END");

    const gridList = $("gridList");
    gridList.replaceChildren();
    grid.forEach((slot, index) => {
      const row = document.createElement("div");
      row.className = "checkpoint-item grid-item";
      const numberCell = document.createElement("span");
      numberCell.textContent = `P${String(index + 1).padStart(2, "0")}`;
      const positionCell = document.createElement("span");
      positionCell.textContent = coordinate(slot);
      const remove = document.createElement("button");
      remove.textContent = "REMOVE";
      remove.addEventListener("click", () => emitEditor("removeGridSlot", { index: index + 1 }));
      row.append(numberCell, positionCell, remove);
      gridList.append(row);
    });

    const list = $("checkpointList");
    list.replaceChildren();
    checkpoints.forEach((checkpoint, index) => {
      const row = document.createElement("div");
      row.className = "checkpoint-item";
      const numberCell = document.createElement("span");
      numberCell.textContent = String(index + 1).padStart(2, "0");
      const positionCell = document.createElement("span");
      positionCell.textContent = coordinate(checkpoint);
      const remove = document.createElement("button");
      remove.textContent = "REMOVE";
      remove.addEventListener("click", () => emitEditor("removeCheckpoint", { index: index + 1 }));
      row.append(numberCell, positionCell, remove);
      list.append(row);
    });

    const catalog = $("editorCatalog");
    catalog.replaceChildren();
    for (const course of editor.courses || []) {
      const row = document.createElement("div");
      row.className = "editor-course";
      const name = document.createElement("b");
      name.textContent = `${course.selected ? "● " : ""}${String(course.name || course.id).slice(0, 34)} · ${integer(course.gridCapacity)}G · ${String(course.vehicleLabel || "CAR").slice(0, 24)}`;
      const load = document.createElement("button");
      load.textContent = course.builtin ? "COPY" : "EDIT";
      load.addEventListener("click", () => emitEditor("load", { id: course.id }));
      const select = document.createElement("button");
      select.textContent = "SELECT";
      select.addEventListener("click", () => emitEditor("select", { id: course.id }));
      row.append(name, load, select);
      if (!course.builtin) {
        const remove = document.createElement("button");
        remove.className = "delete";
        remove.textContent = "DELETE";
        let armed = false;
        let disarmTimer = 0;
        remove.addEventListener("click", () => {
          if (!armed) {
            armed = true;
            remove.classList.add("armed");
            remove.textContent = "CONFIRM";
            clearTimeout(disarmTimer);
            disarmTimer = setTimeout(() => {
              armed = false;
              remove.classList.remove("armed");
              remove.textContent = "DELETE";
            }, 3000);
            return;
          }
          clearTimeout(disarmTimer);
          emitEditor("delete", { id: course.id });
        });
        row.append(remove);
      }
      catalog.append(row);
    }
  }

  function renderGuidance(guidance, inRace, phase) {
    const element = $("checkpointGuide");
    const visible = inRace && phase === "active" && guidance && guidance.visible === true;
    element.classList.toggle("visible", visible);
    if (!visible) {
      guideAngleReady = false;
      return;
    }

    let rawAngle = number(guidance.angle);
    rawAngle = ((rawAngle + 180) % 360 + 360) % 360 - 180;
    if (!guideAngleReady) {
      guideAngle = rawAngle;
      guideAngleReady = true;
    } else {
      const delta = ((rawAngle - guideAngle + 540) % 360) - 180;
      guideAngle += delta;
    }

    const lateral = Math.sin(rawAngle * Math.PI / 180) * 62;
    element.style.setProperty("--guide-angle", `${guideAngle.toFixed(2)}deg`);
    element.style.setProperty("--guide-shift", `${lateral.toFixed(1)}px`);

    const distance = Math.max(0, number(guidance.distance));
    $("guideDistance").textContent = distance >= 1000
      ? `${(distance / 1000).toFixed(1)} KM`
      : `${Math.round(distance)} M`;
    const elevation = number(guidance.elevation);
    const vertical = elevation > 14 ? " · UP" : elevation < -14 ? " · DOWN" : "";
    const near = distance <= Math.max(18, number(guidance.radius, 7) * 2);
    $("guideDirection").textContent = near && !vertical && guidance.direction !== "BEHIND"
      ? "CROSS THE ZONE" : `${String(guidance.direction || "AHEAD").slice(0, 12)}${vertical}`;
    element.classList.toggle("finish-target", guidance.finish === true);
    $("guideCheckpoint").textContent = guidance.finish === true ? "FINISH LINE" :
      `CHECKPOINT ${integer(guidance.checkpoint, 1)} / ${integer(guidance.total, 1)}`;
  }

  function animateCountdown(kind, token) {
    const element = $("countdown");
    if (token === countdownVisualToken) return;
    countdownVisualToken = token;
    element.classList.remove("tick", "ready", "go");
    // Restart the keyframe for each authoritative 3/2/1 edge.
    void element.offsetWidth;
    element.classList.add(kind);
  }

  function render(payload) {
    state = payload && typeof payload === "object" ? payload : state;
    const phase = String(state.phase || "waiting");
    const participant = state.participant === true;
    const inRace = participant && ["grid", "countdown", "active"].includes(phase);
    const panelOpen = state.panelOpen === true;
    const boardOpen = state.boardHeld === true || (participant && phase === "results");
    const course = state.course || {};
    const row = selfRow() || {};
    const next = state.nextCheckpoint || {};
    const position = integer(row.rank, 0);

    body.dataset.phase = participant ? phase : "waiting";
    body.classList.toggle("has-activity", participant || state.queued === true);
    body.classList.toggle("in-race", inRace);
    body.classList.toggle("editor-active", Boolean(state.editor && state.editor.open !== false));
    body.classList.toggle("panel-open", panelOpen);
    body.classList.toggle("board-open", boardOpen);
    body.classList.toggle("chat-open", state.chatOpen === true);
    body.classList.toggle("notice-open", state.noticeOpen === true);

    $("hudCourse").textContent = String(course.name || "RACE").slice(0, 40);
    $("hudPosition").textContent = position ? `P${position}` : "--";
    $("hudLapLabel").textContent = course.type === "sprint" ? "FORMAT" : "LAP";
    $("hudLap").textContent = course.type === "sprint" ? "SPRINT" : `${integer(state.lap, 1)} / ${integer(state.laps, 1)}`;
    $("hudCheckpoint").textContent = `${Math.min(integer(state.checkpointIndex, 1), integer(state.totalCheckpoints, 1))} / ${integer(state.totalCheckpoints, 1)}`;
    const finishWindowActive = state.finishWindowActive === true && phase === "active";
    $("raceBar").classList.toggle("finish-window", finishWindowActive);
    $("hudTimeLabel").textContent = finishWindowActive ? "FINISH WINDOW" : "RACE TIME";
    $("hudTime").textContent = finishWindowActive
      ? raceTime(state.remainingMs, true) : raceTime(state.elapsedMs);
    $("nextIndex").textContent = `${integer(next.index, integer(state.checkpointIndex, 1))} / ${integer(state.totalCheckpoints, 1)}`;
    $("nextLap").textContent = course.type === "sprint" ? "POINT TO POINT" : `LAP ${integer(state.lap, 1)}/${integer(state.laps, 1)}`;
    $("bestLap").textContent = `BEST ${state.bestLapMs != null ? raceTime(state.bestLapMs) : "--:--.---"}`;
    renderGuidance(state.guidance, inRace, phase);

    const phaseName = phaseNames[phase] || phase.toUpperCase();
    $("boardPhase").textContent = finishWindowActive ? "FINISH WINDOW" : phaseName;
    $("boardTime").textContent = finishWindowActive
      ? raceTime(state.remainingMs, true)
      : phase === "grid" || phase === "countdown" || phase === "forming"
      ? raceTime(state.remainingMs, true) : raceTime(state.elapsedMs);
    $("boardCourse").textContent = String(course.name || "RACE CLASSIFICATION").slice(0, 64);
    $("boardMeta").textContent = `${String(course.type || "circuit").toUpperCase()} · ${integer(course.laps, 1)} LAP${integer(course.laps, 1) === 1 ? "" : "S"} · ${integer(course.checkpointCount, state.totalCheckpoints)} CHECKPOINTS`;

    const onGrid = participant && phase === "grid";
    const countdownVisible = participant && (onGrid || phase === "countdown" || goActive);
    $("countdown").classList.toggle("visible", countdownVisible);
    if (goActive) {
      animateCountdown("go", "go");
      $("countdownValue").textContent = "GO!";
      $("countdownLabel").textContent = "GREEN LIGHT";
      $("countdownCourse").textContent = String(course.name || "RACE STARTED").toUpperCase().slice(0, 64);
    } else if (onGrid) {
      const vehicle = state.vehicle || {};
      if (state.gridLoadActive === true) {
        const loadSeconds = Math.max(1, Math.ceil(number(state.remainingMs) / 1000));
        animateCountdown("ready", `grid-load:${loadSeconds}`);
        $("countdownValue").textContent = String(loadSeconds);
        $("countdownLabel").textContent = "GRID LOADING";
        $("countdownCourse").textContent = vehicle.ready === true
          ? "DRIVER LOCKED · WAITING FOR ALL PLAYERS"
          : `${String(vehicle.label || "RACE VEHICLE")} · AUTOMATIC BOARDING`.toUpperCase().slice(0, 64);
      } else {
        animateCountdown("ready", `grid:${vehicle.ready === true ? "ready" : "enter"}`);
        $("countdownValue").textContent = vehicle.ready === true ? "✓" : "SYNC";
        $("countdownLabel").textContent = vehicle.ready === true ? "DRIVER LOCKED" : "BOARDING VEHICLE";
        $("countdownCourse").textContent = vehicle.ready === true
          ? "WAITING FOR THE GRID"
          : `${String(vehicle.label || "RACE VEHICLE")} · AUTOMATIC DRIVER ASSIGNMENT`.toUpperCase().slice(0, 64);
      }
    } else {
      const count = Math.min(3, Math.max(1, Math.ceil(number(state.remainingMs) / 1000)));
      animateCountdown("tick", `countdown:${count}`);
      $("countdownValue").textContent = String(count);
      $("countdownLabel").textContent = "START SEQUENCE";
      $("countdownCourse").textContent = String(course.name || "PREPARE TO RACE").toUpperCase().slice(0, 64);
    }

    const result = state.result || {};
    const showResult = participant && phase === "results";
    $("resultBanner").classList.toggle("visible", showResult);
    if (showResult) {
      const won = String(result.winnerId) === String(state.playerId);
      $("resultTitle").textContent = won ? "VICTORY" : position ? `P${position} FINISH` : "RACE OVER";
      $("resultText").textContent = result.winnerName
        ? `${String(result.winnerName).slice(0, 48)} wins · ${integer(result.finishers)} classified finisher(s).`
        : "No classified finisher.";
    }

    const randomPending = state.randomCourseRotation === true && state.courseLocked !== true;
    $("courseSelectionLabel").textContent = randomPending ? "RANDOM ROTATION" : "NEXT COURSE";
    $("panelCourse").textContent = randomPending
      ? "RANDOM COURSE" : String(course.name || "NO COURSE").slice(0, 64);
    $("panelDescription").textContent = randomPending
      ? "The route is drawn when the join window opens. Consecutive heats never repeat."
      : String(course.description || "No description.").slice(0, 240);
    $("panelFormat").textContent = randomPending ? "RANDOM" : String(course.type || "--").toUpperCase();
    $("panelLaps").textContent = randomPending ? "--" : String(integer(course.laps, 1));
    $("panelGates").textContent = randomPending ? "--" : String(integer(course.checkpointCount));
    $("panelQueue").textContent = `${integer(state.queueCount)} / ${integer(state.maximumRacers, 1)}`;
    const queueRatio = Math.min(1, integer(state.queueCount) / Math.max(1, integer(state.maximumRacers, 1)));
    $("queueProgress").style.width = `${Math.round(queueRatio * 100)}%`;
    $("queueCopy").textContent = state.queued
      ? phase === "forming" ? `Race locks in ${(number(state.remainingMs) / 1000).toFixed(1)}s · P${integer(state.queuePosition)} · ${integer(state.queueCount)}/${integer(state.maximumRacers, 1)} drivers.` : `Queued in position ${integer(state.queuePosition)}.`
      : participant ? "You are classified in the current heat." : phase === "active" ? "Current heat active. Join the next one." : "Join the next heat.";
    $("joinButton").classList.toggle("hidden", state.canJoin !== true);
    $("leaveQueueButton").classList.toggle("hidden", state.canLeaveQueue !== true);
    $("leaveRaceButton").classList.toggle("hidden", state.canLeaveRace !== true);

    renderLiveRows();
    renderBoard();
    renderCourses(Array.isArray(state.courses) ? state.courses : []);
    renderEditor(state.editor);
  }

  function toast(payload) {
    const item = document.createElement("div");
    item.className = `toast ${String(payload.kind || "info")}`;
    const title = document.createElement("strong");
    title.textContent = String(payload.title || "RACE").slice(0, 64);
    const message = document.createElement("span");
    message.textContent = String(payload.message || "").slice(0, 180);
    item.append(title, message);
    $("toasts").prepend(item);
    setTimeout(() => item.classList.add("leaving"), 4100);
    setTimeout(() => item.remove(), 4550);
  }

  function pulse(payload) {
    if (String(payload.kind || "") === "go") {
      clearTimeout(goTimer);
      goActive = true;
      countdownVisualToken = "";
      render(state);
      goTimer = setTimeout(() => {
        goActive = false;
        countdownVisualToken = "";
        render(state);
      }, 1250);
      return;
    }
    clearTimeout(pulseTimer);
    const element = $("pulse");
    element.className = `pulse visible ${String(payload.kind || "")}`;
    $("pulseText").textContent = String(payload.text || "CHECKPOINT").slice(0, 64);
    pulseTimer = setTimeout(() => element.classList.remove("visible"), payload.kind === "finish" ? 3200 : 1350);
  }

  function emitAction(action) {
    Open77.emit("race:action", { action });
  }

  function syncFields() {
    emitEditor("fields", {
      name: $("editName").value,
      description: $("editDescription").value,
      vehicle: dropdownValue("editVehicle"),
      type: dropdownValue("editType"),
      laps: integer($("editLaps").value, 1),
      checkpointRadius: number($("editRadius").value, 7)
    });
  }

  function closeFocusedPanel() {
    // Hiding a CEF page does not guarantee the focused input receives a normal
    // browser blur/change edge first. Publish the current metadata explicitly
    // so closing options and saving later from drive mode cannot restore stale
    // text or format values.
    if (state.editor && state.editor.open !== false) syncFields();
    emitAction("close");
  }

  body.querySelectorAll(".tab").forEach(button =>
    button.addEventListener("click", () => setTab(button.dataset.tab)));
  $("joinButton").addEventListener("click", () => emitAction("join"));
  $("backFreeroam").addEventListener("click", () => emitAction("freeroam"));
  $("openEditor").addEventListener("click", () => emitAction("editor"));
  $("leaveQueueButton").addEventListener("click", () => emitAction("leaveQueue"));
  $("leaveRaceButton").addEventListener("click", () => emitAction("leaveRace"));
  $("closePanel").addEventListener("click", closeFocusedPanel);
  $("scrim").addEventListener("click", closeFocusedPanel);
  $("editName").addEventListener("change", syncFields);
  $("editDescription").addEventListener("change", syncFields);
  $("editLaps").addEventListener("change", syncFields);
  $("editRadius").addEventListener("change", syncFields);
  $("captureStart").addEventListener("click", () => { syncFields(); emitEditor("captureStart"); });
  $("captureGrid").addEventListener("click", () => { syncFields(); emitEditor("captureGrid"); });
  $("addCheckpoint").addEventListener("click", () => { syncFields(); emitEditor("addCheckpoint"); });
  $("undoGrid").addEventListener("click", () => emitEditor("undoGrid"));
  $("undoCheckpoint").addEventListener("click", () => emitEditor("undo"));
  $("newCourse").addEventListener("click", () => emitEditor("new"));
  $("saveCourse").addEventListener("click", () => { syncFields(); emitEditor("save"); });
  $("respawnEditorVehicle").addEventListener("click", () => emitEditor("spawnVehicle"));
  $("exitEditor").addEventListener("click", () => emitEditor("close"));
  document.addEventListener("keydown", event => {
    if (event.key === "Escape" && body.classList.contains("panel-open")) {
      const dropdown = body.querySelector(".custom-dropdown.open");
      if (dropdown) {
        closeCustomDropdowns();
        dropdown.querySelector(".custom-dropdown-trigger").focus();
      } else closeFocusedPanel();
    }
  });

  initializeCustomDropdowns();

  Open77.on("race:render", render);
  Open77.on("race:notice", toast);
  Open77.on("race:pulse", pulse);
  Open77.on("race:editorOpen", () => setTab("editor"));
  Open77.on("race:panel", payload => body.classList.toggle("panel-open", payload && payload.open === true));
  Open77.on("race:initialize", () => Open77.emit("race:ready", {}));
  Open77.emit("race:ready", {});
})();

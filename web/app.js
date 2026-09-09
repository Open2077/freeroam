(() => {
  "use strict";

  const body = document.getElementById("freeroam-menu");
  const toast = document.getElementById("toast");
  let toastTimer = null;
  let state = {
    locations: [], spawns: [],
    vehicles: { catalog: [], allowCustomModels: false },
    weapons: { catalog: [], enabled: false, defaultReserve: 500, maximumReserve: 5000 },
    player: {},
  };
  let selectedSlot = 1;
  let vehicleCategory = "All";
  let weaponCategory = "All";
  let weaponSlots = [];
  let garageState = { count: 0, maximum: 0 };
  let playerState = { available: false };

  const send = (type, extra) => Open77.emit(
    "freeroam:action", Object.assign({ type }, extra || {}));
  const close = () => Open77.emit("freeroam:close", {});
  // An empty Lua table crosses the bridge as {}, not []; never iterate raw.
  const asArray = value => Array.isArray(value) ? value : [];
  const text = value => String(value || "").toLocaleLowerCase();

  function showToast(ok, message) {
    toast.textContent = message;
    toast.classList.toggle("error", !ok);
    toast.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove("show"), 3600);
  }

  // Tabs -----------------------------------------------------------------

  for (const tab of body.querySelectorAll(".tab")) {
    tab.addEventListener("click", () => {
      if (tab.dataset.tab === "animations") {
        Open77.emit("animations:open", {});
        return;
      }
      if (tab.dataset.tab === "race") {
        Open77.emit("freeroam:race", {});
        return;
      }
      for (const other of body.querySelectorAll(".tab"))
        other.classList.toggle("active", other === tab);
      for (const page of body.querySelectorAll(".page"))
        page.classList.toggle("active", page.id === "page-" + tab.dataset.tab);
      if (tab.dataset.tab === "weapons") send("weaponSnapshot", {});
      if (tab.dataset.tab === "pvp") Open77.emit("pvp:open", {});
    });
  }

  // Catalog rendering ----------------------------------------------------

  function categories(items) {
    return ["All", ...new Set(asArray(items).map(item => item.category || "Other"))];
  }

  function renderFilters(id, items, active, select) {
    const host = document.getElementById(id);
    host.replaceChildren();
    for (const category of categories(items)) {
      const button = document.createElement("button");
      button.textContent = category;
      button.classList.toggle("active", category === active);
      button.addEventListener("click", () => select(category));
      host.append(button);
    }
  }

  function matches(item, category, query) {
    if (category !== "All" && item.category !== category) return false;
    if (!query) return true;
    return text(`${item.label} ${item.key} ${item.category} ${item.record}`).includes(query);
  }

  function card(item, action) {
    const button = document.createElement("button");
    button.className = "catalog-card";
    button.title = item.record || "";
    const label = document.createElement("strong");
    label.textContent = item.label || item.key;
    const meta = document.createElement("small");
    meta.textContent = `${item.category || "Other"} · ${item.key}`;
    button.append(label, meta);
    button.addEventListener("click", action);
    return button;
  }

  function renderVehicles() {
    const vehicles = state.vehicles && typeof state.vehicles === "object" ? state.vehicles : {};
    const items = asArray(vehicles.catalog);
    const query = text(document.getElementById("vehicle-search").value.trim());
    const grid = document.getElementById("vehicle-grid");
    grid.replaceChildren();
    renderFilters("vehicle-filters", items, vehicleCategory, category => {
      vehicleCategory = category;
      renderVehicles();
    });
    for (const item of items) {
      if (!matches(item, vehicleCategory, query)) continue;
      grid.append(card(item, () => send("car", { model: item.key })));
    }

    document.getElementById("vehicle-custom").style.display =
      vehicles.allowCustomModels ? "" : "none";
    const max = Number(vehicles.maxPerPlayer) || 0;
    const count = Number(garageState.count) || 0;
    const effectiveMax = Number(garageState.maximum) || max;
    document.getElementById("vehicle-hint").textContent = effectiveMax > 0
      ? `Server-owned garage: ${count}/${effectiveMax}; the oldest is recycled at the limit.`
      : "Vehicles are server-owned. No per-player spawn quota is enabled.";
    const latest = garageState.latest && typeof garageState.latest === "object"
      ? garageState.latest : null;
    const identity = latest && (latest.label || latest.record || `VEHICLE ${latest.id}`);
    document.getElementById("vehicle-latest").textContent = latest
      ? `LATEST · ${identity} · ${latest.engineOn ? "ENGINE ON" : "ENGINE OFF"} · ` +
        `${latest.locked ? "LOCKED" : "UNLOCKED"} · ` +
        `${latest.lightsOn ? "LIGHTS ON" : "LIGHTS OFF"}`
      : "GARAGE EMPTY";
  }

  function renderWeapons() {
    const weapons = state.weapons && typeof state.weapons === "object" ? state.weapons : {};
    const items = asArray(weapons.catalog);
    const query = text(document.getElementById("weapon-search").value.trim());
    const grid = document.getElementById("weapon-grid");
    grid.replaceChildren();
    renderFilters("weapon-filters", items, weaponCategory, category => {
      weaponCategory = category;
      renderWeapons();
    });
    for (const item of items) {
      if (!matches(item, weaponCategory, query)) continue;
      const button = card(item, () => send("weaponEquip", {
        key: item.key,
        slot: selectedSlot,
      }));
      const equipped = weaponSlots.find(value => Number(value.slot) === selectedSlot) || {};
      button.classList.toggle("equipped", equipped.record === item.record);
      grid.append(button);
    }
    document.getElementById("ammo-reserve").placeholder =
      `reserve 0-${Number(weapons.maximumReserve) || 5000}`;
    if (!document.getElementById("ammo-reserve").value)
      document.getElementById("ammo-reserve").value = String(Number(weapons.defaultReserve) || 500);
  }

  function renderLoadout() {
    const host = document.getElementById("weapon-loadout");
    host.replaceChildren();
    for (let slot = 1; slot <= 3; slot += 1) {
      const value = weaponSlots.find(item => Number(item.slot) === slot) || {};
      const row = document.createElement("button");
      row.className = "loadout-row";
      row.classList.toggle("selected", slot === selectedSlot);
      const name = document.createElement("strong");
      const record = value.record || value.tweakDbId || "";
      const configured = asArray(state.weapons && state.weapons.catalog)
        .find(item => item.record === value.record);
      const display = configured && configured.label ? configured.label : record || "Empty";
      name.textContent = `SLOT ${slot} · ${display}`;
      row.title = record;
      const status = document.createElement("small");
      const ammo = value.ammo && typeof value.ammo === "object" ? value.ammo : {};
      const flags = [value.active ? "ACTIVE" : "", value.drawn ? "DRAWN" : ""]
        .filter(Boolean).join(" · ") || "INACTIVE";
      status.textContent = Number(ammo.total) >= 0
        ? `${flags} · reserve ${ammo.reserve} · mag ${ammo.magazine}/${ammo.capacity}`
        : flags;
      row.append(name, status);
      row.addEventListener("click", () => selectSlot(slot));
      host.append(row);
    }
  }

  function selectSlot(slot) {
    selectedSlot = slot;
    for (const button of body.querySelectorAll("#weapon-slots button"))
      button.classList.toggle("active", Number(button.dataset.slot) === slot);
    renderLoadout();
  }

  function renderTravel() {
    const locations = document.getElementById("location-list");
    locations.replaceChildren();
    for (const location of asArray(state.locations)) {
      const button = document.createElement("button");
      const label = document.createElement("span");
      label.textContent = location.label || location.name;
      const detail = document.createElement("i");
      const p = location.position || {};
      detail.textContent = `${location.district || "Night City"} · ${Math.round(p.x)}, ${Math.round(p.y)}, ${Math.round(p.z)}`;
      button.append(label, detail);
      button.addEventListener("click", () => send("goto", { name: location.name }));
      locations.append(button);
    }

    const spawns = document.getElementById("spawn-list");
    spawns.replaceChildren();
    for (const point of asArray(state.spawns)) {
      const button = document.createElement("button");
      const label = document.createElement("span");
      label.textContent = point.label || point.name;
      const coords = document.createElement("i");
      const p = point.position || {};
      coords.textContent = `${Math.round(p.x)}, ${Math.round(p.y)}, ${Math.round(p.z)}`;
      button.append(label, coords);
      button.addEventListener("click", () => send("spawn", { name: point.name }));
      spawns.append(button);
    }
  }

  function render() {
    renderVehicles();
    renderWeapons();
    renderLoadout();
    renderTravel();
    const player = state.player && typeof state.player === "object" ? state.player : {};
    document.getElementById("player-restore").style.display = player.allowRestore ? "" : "none";
    document.getElementById("godmode-controls").style.display = player.allowGodMode ? "" : "none";
    renderPlayerState();
  }

  function renderPlayerState() {
    const host = document.getElementById("player-status");
    if (!playerState.available) {
      host.textContent = "PLAYER STATE UNAVAILABLE";
      host.classList.remove("signal");
      return;
    }
    const health = Math.round(Number(playerState.health) || 0);
    const maximum = Math.round(Number(playerState.maximumHealth) || 0);
    const armor = Math.round(Number(playerState.armor) || 0);
    host.textContent = `HEALTH ${health}/${maximum} · ARMOR ${armor} · ` +
      (playerState.godMode ? "GOD MODE ON" : "GOD MODE OFF");
    host.classList.toggle("signal", playerState.godMode === true);
  }

  // Static controls ------------------------------------------------------

  document.getElementById("close").addEventListener("click", close);
  document.getElementById("vehicle-search").addEventListener("input", renderVehicles);
  document.getElementById("weapon-search").addEventListener("input", renderWeapons);
  document.getElementById("vehicle-delete").addEventListener("click", () => send("dv", {}));
  document.getElementById("vehicle-delete-all").addEventListener("click", () => send("dv", { all: true }));
  document.getElementById("vehicle-spawn").addEventListener("click", () => {
    const record = document.getElementById("vehicle-record").value.trim();
    if (record) send("car", { model: record });
  });
  document.getElementById("vehicle-repair").addEventListener("click", () => send("vehicleRepair", {}));
  document.getElementById("vehicle-engine-on").addEventListener("click", () => send("vehicleEngine", { enabled: true }));
  document.getElementById("vehicle-engine-off").addEventListener("click", () => send("vehicleEngine", { enabled: false }));
  document.getElementById("vehicle-lock").addEventListener("click", () => send("vehicleLock", { enabled: true }));
  document.getElementById("vehicle-unlock").addEventListener("click", () => send("vehicleLock", { enabled: false }));
  document.getElementById("vehicle-lights").addEventListener("click", () => send("vehicleLights", { enabled: true }));
  document.getElementById("vehicle-lights-off").addEventListener("click", () => send("vehicleLights", { enabled: false }));

  for (const button of body.querySelectorAll("#weapon-slots button"))
    button.addEventListener("click", () => selectSlot(Number(button.dataset.slot)));
  document.getElementById("weapon-ammo").addEventListener("click", () => {
    const reserveText = document.getElementById("ammo-reserve").value.trim();
    const magazineText = document.getElementById("ammo-magazine").value.trim();
    const reserve = Number(reserveText);
    const maximum = Number(state.weapons && state.weapons.maximumReserve) || 5000;
    if (!Number.isInteger(reserve) || reserve < 0 || reserve > maximum)
      return showToast(false, `reserve must be an integer from 0 to ${maximum}`);
    const payload = { slot: selectedSlot, reserve };
    if (magazineText) {
      const magazine = Number(magazineText);
      if (!Number.isInteger(magazine) || magazine < 0)
        return showToast(false, "magazine must be a positive integer");
      payload.magazine = magazine;
    }
    send("weaponAmmo", payload);
  });
  document.getElementById("weapon-activate").addEventListener("click", () =>
    send("weaponActivate", { slot: selectedSlot }));
  document.getElementById("weapon-refresh").addEventListener("click", () => send("weaponSnapshot", {}));
  document.getElementById("weapon-holster").addEventListener("click", () => send("weaponHolster", {}));
  document.getElementById("weapon-remove").addEventListener("click", () =>
    send("weaponRemove", { slot: selectedSlot }));

  document.getElementById("coord-go").addEventListener("click", () => {
    const value = id => document.getElementById(id).value.trim();
    const x = Number(value("coord-x"));
    const y = Number(value("coord-y"));
    const z = Number(value("coord-z"));
    const heading = Number(value("coord-h") || "0");
    if (![x, y, z, heading].every(Number.isFinite))
      return showToast(false, "invalid coordinates");
    send("tpc", { x, y, z, heading });
  });
  document.getElementById("player-wardrobe").addEventListener("click", () => send("wardrobe", {}));
  document.getElementById("player-spawn").addEventListener("click", () => send("spawn", {}));
  document.getElementById("player-restore").addEventListener("click", () => send("restore", {}));
  document.getElementById("player-revive").addEventListener("click", () => send("revive", {}));
  document.getElementById("player-god-on").addEventListener("click", () => send("godMode", { enabled: true }));
  document.getElementById("player-god-off").addEventListener("click", () => send("godMode", { enabled: false }));
  document.getElementById("player-suicide").addEventListener("click", () => send("suicide", {}));

  document.addEventListener("keydown", event => {
    if (event.key === "Escape") { event.preventDefault(); close(); }
  });

  // Bridge ---------------------------------------------------------------

  Open77.on("freeroam:state", payload => {
    if (payload && typeof payload === "object") state = payload;
    render();
  });
  Open77.on("freeroam:weapons", payload => {
    weaponSlots = asArray(payload && payload.slots);
    renderWeapons();
    renderLoadout();
  });
  Open77.on("freeroam:garage", payload => {
    garageState = payload && typeof payload === "object" ? payload : { count: 0, maximum: 0 };
    renderVehicles();
  });
  Open77.on("freeroam:player", payload => {
    playerState = payload && typeof payload === "object" ? payload : { available: false };
    renderPlayerState();
  });
  Open77.on("freeroam:open", () => body.classList.add("open"));
  Open77.on("freeroam:closed", () => body.classList.remove("open"));
  Open77.on("freeroam:result", payload => {
    if (payload && payload.text) showToast(payload.ok === true, payload.text);
  });

  Open77.ready();
  Open77.emit("freeroam:ready", {});
})();

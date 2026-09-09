(() => {
  "use strict";

  const feedEl = document.getElementById("feed");
  const hitmarkerEl = document.getElementById("hitmarker");
  const flashEl = document.getElementById("damage-flash");

  let maxEntries = 5;
  let entryTtlMs = 6000;
  let hitmarkerTimer = 0;
  let flashTimer = 0;

  function addEntry(payload) {
    const killer = String((payload && payload.killer) || "").slice(0, 48);
    const victim = String((payload && payload.victim) || "").slice(0, 48);
    if (!victim) return;

    const entry = document.createElement("div");
    entry.className = "entry" + (killer ? "" : " unattributed");

    if (killer) {
      const killerEl = document.createElement("span");
      killerEl.className = "killer";
      killerEl.textContent = killer;
      entry.append(killerEl);
    }
    const skull = document.createElement("span");
    skull.className = "skull";
    // The design language uses tracked labels, never emoji. Keep the transport
    // neutral and let this compact action label carry the relationship.
    skull.textContent = "ELIM";
    const victimEl = document.createElement("span");
    victimEl.className = "victim";
    victimEl.textContent = victim;
    entry.append(skull, victimEl);

    feedEl.append(entry);
    requestAnimationFrame(() => entry.classList.add("visible"));
    while (feedEl.children.length > maxEntries) feedEl.firstChild.remove();
    setTimeout(() => {
      entry.classList.add("expiring");
      setTimeout(() => entry.remove(), 220);
    }, entryTtlMs);
  }

  function showHitmarker(payload) {
    hitmarkerEl.classList.remove("show", "lethal", "headshot");
    if (payload && payload.lethal) hitmarkerEl.classList.add("lethal");
    else if (payload && payload.bodyPart === "head") hitmarkerEl.classList.add("headshot");
    // Restart the CSS animation even when hits land back to back.
    void hitmarkerEl.offsetWidth;
    hitmarkerEl.classList.add("show");
    clearTimeout(hitmarkerTimer);
    hitmarkerTimer = setTimeout(() => hitmarkerEl.classList.remove("show"), 240);
  }

  function showDamageFlash() {
    flashEl.classList.remove("show");
    void flashEl.offsetWidth;
    flashEl.classList.add("show");
    clearTimeout(flashTimer);
    flashTimer = setTimeout(() => flashEl.classList.remove("show"), 440);
  }

  Open77.on("killfeed:config", payload => {
    if (payload && Number(payload.maxEntries) > 0) maxEntries = Number(payload.maxEntries);
    if (payload && Number(payload.entryTtlMs) > 0) entryTtlMs = Number(payload.entryTtlMs);
  });
  Open77.on("killfeed:entry", addEntry);
  Open77.on("killfeed:hit", showHitmarker);
  Open77.on("killfeed:damaged", showDamageFlash);

  Open77.ready();
  Open77.emit("killfeed:ready", {});
})();

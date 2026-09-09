(() => {
  "use strict";

  const body = document.body;
  const rowsEl = document.getElementById("rows");
  const countEl = document.getElementById("count");
  const emptyEl = document.getElementById("empty");

  const asArray = value => Array.isArray(value) ? value : [];

  function formatDistance(metres) {
    const value = Number(metres) || 0;
    if (value >= 1000) return (value / 1000).toFixed(1) + " km";
    return Math.round(value) + " m";
  }

  function render(payload) {
    const players = asArray(payload && payload.players);
    countEl.textContent = String(players.length);
    rowsEl.replaceChildren();

    for (const player of players) {
      const row = document.createElement("div");
      row.className = "row";
      // Every row is a player on the server. Only the ones streamed near the
      // local player carry a distance; the others are somewhere in the city.
      const streamed = player.streamed === true && player.distance !== null && player.distance !== undefined;
      const distance = Number(player.distance) || 0;
      if (player.self) row.classList.add("self");
      else if (!streamed) row.classList.add("far");
      else if (distance <= 25) row.classList.add("near");

      const name = document.createElement("span");
      name.className = "name";
      name.textContent = String(player.label || "Player").slice(0, 64);

      const id = document.createElement("span");
      id.className = "id";
      id.textContent = String(player.id || "?");

      const dist = document.createElement("span");
      dist.className = "dist";
      dist.textContent = player.self ? "YOU" : (streamed ? formatDistance(distance) : "\u2014");

      row.append(name, id, dist);
      rowsEl.append(row);
    }

    emptyEl.textContent = payload && payload.rosterKnown === false
      ? "// WAITING FOR THE SERVER ROSTER"
      : "// NO ONE ELSE ON THE SERVER";
    emptyEl.classList.toggle("hidden", players.length > 0);
  }

  Open77.on("scoreboard:data", render);
  Open77.on("scoreboard:open", () => body.classList.add("open"));
  Open77.on("scoreboard:closed", () => body.classList.remove("open"));

  Open77.ready();
  Open77.emit("scoreboard:ready", {});
})();

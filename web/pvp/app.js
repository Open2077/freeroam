(() => {
  'use strict';
  const $ = id => document.getElementById(`pvp-${id}`);
  const list = value => Array.isArray(value) ? value : [];
  const number = value => Number.isFinite(Number(value)) ? Number(value) : 0;
  const write = (id, value) => { $(id).textContent = String(value ?? ''); };
  const emit = (action, data = {}) => Open77.emit('pvp:action', { action, ...data });
  let state = {}, weapons = [], chosen = '', anchor = performance.now(), board = false, noticeTimer, weaponSignature = '';
  const formatNames = { ffa:'FREE-FOR-ALL', '1v1':'DUEL', '2v2':'DOUBLES', '3v3':'SQUADS' };
  function open() {
    for (const tab of document.querySelectorAll('#freeroam-menu .tab')) tab.classList.toggle('active', tab.dataset.tab === 'pvp');
    for (const page of document.querySelectorAll('#freeroam-menu .page')) page.classList.toggle('active', page.id === 'page-pvp');
  }
  function formatTime(ms) {
    const seconds = Math.ceil(Math.max(0,ms) / 1000);
    return `${Math.floor(seconds/60).toString().padStart(2,'0')}:${(seconds%60).toString().padStart(2,'0')}`;
  }
  function notify(payload) {
    write('notice-title', payload.title || 'PVP'); write('notice-body', payload.message);
    $('notice').hidden = false; clearTimeout(noticeTimer);
    noticeTimer = setTimeout(() => { $('notice').hidden = true; }, 3600);
  }
  function renderWeapons() {
    const query = $('weapon-search').value.trim().toLowerCase();
    const kits = list(state.arena?.kits);
    const inArena = !!state.arena, locked = inArena && state.roundState !== 'buy';
    const entries = inArena ? kits : weapons;
    const signature = JSON.stringify([query,entries,inArena,state.arena?.kit,chosen,locked]);
    if (signature === weaponSignature) return;
    weaponSignature = signature;
    $('weapons').replaceChildren();
    for (const item of entries) {
      if (query && !`${item.label} ${item.category || ''} ${item.key}`.toLowerCase().includes(query)) continue;
      const button = document.createElement('button'); button.className = 'pvp-weapon';
      const selected = item.key === (inArena ? state.arena.kit : chosen);
      button.setAttribute('aria-pressed', String(selected));
      const name = document.createElement('span'); name.textContent = item.label || item.key;
      const category = document.createElement('small'); category.textContent = selected ? 'SELECTED' : (item.category || 'ARENA KIT').toUpperCase();
      button.append(name,category);
      button.disabled = locked;
      button.addEventListener('click', () => { emit(inArena ? 'kit' : 'weapon', {key:item.key}); });
      $('weapons').append(button);
    }
    if (!$('weapons').childElementCount) {
      const empty = document.createElement('p'); empty.textContent = locked ? 'Kit locked for this round.' : query ? 'No matching weapons.' : 'Loading the server arsenal.';
      $('weapons').append(empty);
    }
    write('loadout-hint', locked ? 'Reopen /pvp during the next buy phase to change your arena kit.'
      : inArena ? 'Buy phase. Both teams receive the same kit list. Choose before the timer ends.'
      : 'Choose your free-for-all primary. Changes during a fight apply on respawn.');
  }
  function renderRows() {
    $('rows').replaceChildren();
    for (const [index,row] of list(state.rows).entries()) {
      const tr = document.createElement('tr'); tr.classList.toggle('self', String(row.id) === String(state.playerId));
      const team = state.arena && number(row.team) > 0 ? (number(row.team) === number(state.arena.side) ? 'ALLY' : 'OPPONENT') : '';
      if (team) tr.classList.add(team.toLowerCase());
      const name = `${row.name || 'Player'}${row.bot ? ' [BOT]' : ''}${team ? ` · ${team}` : ''}`;
      for (const value of [row.rank || index+1, name, number(row.kills), number(row.deaths), number(row.assists), number(row.score)]) {
        const td = document.createElement('td'); td.textContent = String(value); tr.append(td);
      }
      $('rows').append(tr);
    }
  }
  function render() {
    const participant = state.participant === true, queued = state.playerState === 'queued';
    const arena = state.arena, me = state.self || {};
    $('hud').hidden = !participant;
    $('queue-dock').hidden = !queued || participant;
    const queueFormat = state.queueFormat || state.queuedFormat || state.queue?.format || 'ARENA';
    const current = participant ? `${formatNames[state.mode] || 'PVP'} · IN MATCH` : `${queueFormat.toUpperCase()} · QUEUED`;
    write('current-label', current); write('queue-label', current);
    write('current-detail', participant ? 'Leaving returns you to your saved Freeroam position.' : 'You can close the menu and keep exploring.');
    $('current').hidden = !participant && !queued;
    for (const button of document.querySelectorAll('[data-pvp-format]')) button.disabled = participant || queued;
    write('population', `${number(state.instancePlayers)} players · ${number(state.instanceCount)} live instances`);
    for (const label of document.querySelectorAll('[data-pvp-queue]')) {
      const format = label.dataset.pvpQueue;
      const counts = state.arenaQueue || {};
      const item = Array.isArray(counts) ? counts.find(x => x.format === format || x.key === format) : counts[format];
      label.textContent = `${number(typeof item === 'object' ? item?.count ?? item?.players ?? item?.queued : item)} QUEUED`;
    }
    write('mode', formatNames[state.mode] || 'ARENA');
    write('objective', arena ? `ROUND ${number(arena.round)} · FIRST TO ${number(arena.target)}` : `FIRST TO ${number(state.killLimit) || 25} ELIMINATIONS`);
    const alive = list(arena?.aliveByTeam), side = number(arena?.side) || 1;
    write('match-hint', arena ? (state.roundState === 'buy' ? '/PVP · CHOOSE YOUR KIT'
      : `${number(alive[side-1])} ALLIES · ${number(alive[side===1 ? 1 : 0])} OPPONENTS ALIVE`) : '');
    $('scoreline').replaceChildren();
    if (arena) {
      const side = number(arena.side) || 1, wins = list(arena.wins);
      const mine = document.createTextNode(String(number(wins[side-1])));
      const separator = document.createElement('span'); separator.textContent = 'VS';
      const theirs = document.createElement('b'); theirs.textContent = String(number(wins[side===1 ? 1 : 0]));
      $('scoreline').append(mine,separator,theirs);
    }
    write('rank', `P${number(me.rank) || '—'}`); write('kills',number(me.kills)); write('deaths',number(me.deaths)); write('assists',number(me.assists));
    write('streak', number(me.streak) >= 2 ? `${number(me.streak)} ELIMINATION STREAK` : '/PVP · LOADOUT / LEAVE');
    const result = state.phase === 'results' || state.roundState === 'resolved' || state.roundState === 'standings';
    const dead = !result && ['respawning','eliminated','dead'].includes(state.playerState);
    $('death').hidden = !participant || !dead || board;
    write('death-title', state.playerState === 'eliminated' ? 'ROUND OVER FOR YOU' : 'ELIMINATED');
    write('death-detail', state.death?.killerName ? `Eliminated by ${state.death.killerName}` : 'Your next opportunity is coming.');
    $('board').hidden = !participant || (!board && !result);
    const outcome = state.result || {};
    const victory = arena ? number(outcome.winnerSide) === number(arena.side)
      : outcome.winnerId != null && String(outcome.winnerId) === String(state.playerId);
    write('board-title', result ? (victory ? 'VICTORY' : 'MATCH COMPLETE') : 'LIVE STANDINGS');
    write('board-subtitle', result
      ? (arena ? 'Server-confirmed results · Returning to Freeroam after the result timer.' : 'Server-confirmed results · The next round starts automatically.')
      : 'Bots are labelled. Only eligible human matches affect rating.');
    renderRows(); tick();
  }
  function tick() {
    const elapsed = Math.max(0,performance.now()-anchor);
    const remaining = Math.max(0,number(state.remainingMs)-elapsed);
    write('timer',formatTime(remaining));
    write('phase', ({buy:'BUY PHASE',active:'LIVE',playing:'LIVE',between:'NEXT ROUND',results:'RESULTS',resolved:'RESULTS',standings:'RESULTS'})[state.roundState || state.phase] || 'PREPARING');
    $('timer').parentElement.classList.toggle('urgent',remaining < 30000 && remaining > 0);
    const protection = Math.max(0,number(state.self?.protection?.remainingMs)-elapsed);
    $('protection').hidden = !state.participant || protection <= 0;
    write('protection-time',`${Math.ceil(protection/1000)}S`);
    write('respawn', state.playerState === 'respawning' ? `RESPAWN IN ${Math.ceil(Math.max(0,number(state.death?.remainingMs)-elapsed)/1000)}` : 'WAITING FOR THE NEXT ROUND');
  }
  for (const button of document.querySelectorAll('[data-pvp-format]')) button.addEventListener('click', () => {
    emit(button.dataset.pvpFormat === 'ffa' ? 'join' : 'queue', {format:button.dataset.pvpFormat,bots:$('bots').checked});
  });
  $('leave').addEventListener('click', () => emit('leave'));
  $('weapon-search').addEventListener('input', renderWeapons);
  $('sound').addEventListener('change', () => emit('sound',{enabled:$('sound').checked}));
  Open77.on('pvp:open', () => { open(); emit('refresh'); });
  Open77.on('pvp:state', payload => { state = payload || {}; anchor = performance.now(); render(); renderWeapons(); });
  Open77.on('pvp:weapons', payload => { weapons = list(payload.weapons); chosen = payload.chosen || ''; renderWeapons(); });
  Open77.on('pvp:notice', notify);
  Open77.on('pvp:board', payload => { board = payload.open === true; render(); });
  Open77.on('pvp:killfeed', payload => {
    if (!state.participant) return;
    const row = document.createElement('div'); row.className = 'pvp-feed-row';
    const killer = document.createTextNode(`${payload.killerName || payload.killer?.name || 'Environment'}${payload.killerBot ? ' [BOT]' : ''}`);
    const marker = document.createElement('span'); marker.textContent = payload.headshot ? 'HEADSHOT' : 'ELIM';
    const victim = document.createTextNode(`${payload.victimName || payload.victim?.name || 'Player'}${payload.victimBot ? ' [BOT]' : ''}`);
    row.append(killer,marker,victim); $('feed').prepend(row);
    while($('feed').childElementCount > 4) $('feed').lastElementChild.remove();
    setTimeout(() => row.remove(),5000);
  });
  setInterval(tick,100);
  Open77.emit('pvp:ready',{});
})();

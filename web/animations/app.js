(() => {
  'use strict';
  const $ = id => document.getElementById('anim-' + id);
  const model = FreeroamAnimationCatalog;
  const storageKey = 'open77.freeroam.animationFavorites.v1';
  let items = [], selected = '', category = 'all', busy = false, loaded = false, current = null, signature = '';
  let favorites = new Set();
  try {
    const saved = JSON.parse(localStorage.getItem(storageKey) || '[]');
    if (Array.isArray(saved)) favorites = new Set(saved.filter(x => typeof x === 'string' && x.length < 256).slice(0, 100));
  } catch (_) { /* Storage can be disabled by the host. */ }
  const emit = (action, data = {}) => Open77.emit('animations:action', { action, ...data });
  function save() { try { localStorage.setItem(storageKey, JSON.stringify([...favorites])); } catch (_) {} }
  function select(key) {
    selected = key;
    for (const button of $('grid').querySelectorAll('[data-animation]')) {
      button.setAttribute('aria-pressed', String(button.dataset.animation === key));
    }
    renderSelection();
  }
  function renderSelection() {
    const item = items.find(x => x.key === selected);
    $('selected').textContent = item ? `${item.label} · ${item.variant}` : 'Choose an animation';
    $('detail').textContent = item ? `${item.categoryLabel} · ${item.placement === 'ground' ? 'On the ground' : 'Standing'}${item.prop ? ' · Prop: ' + item.prop : ''}` : 'Select a card to see its details.';
    $('tested').textContent = item?.tested ? 'LOCAL MALE CHECKED' : 'EXPERIMENTAL';
    $('tested').classList.toggle('checked', !!item?.tested);
    $('play').disabled = !item || busy;
  }
  function renderFilters() {
    $('filters').replaceChildren();
    for (const [key, label] of Object.entries({ all: 'All', favorites: '★ Favourites', ...model.categories })) {
      const button = document.createElement('button');
      button.type = 'button'; button.textContent = label;
      button.setAttribute('aria-pressed', String(key === category));
      button.addEventListener('click', () => { category = key; renderFilters(); renderCards(); });
      $('filters').append(button);
    }
  }
  function renderCards() {
    const visible = model.filter(items, category, $('search').value, favorites);
    $('grid').replaceChildren();
    $('total').textContent = loaded ? items.length : '—';
    $('count').textContent = loaded ? `${visible.length} / ${items.length} VARIANTS · ${new Set(items.map(x => x.profile)).size} FAMILIES` : 'Loading collection…';
    $('empty').hidden = visible.length > 0 || !loaded;
    $('empty-title').textContent = category === 'favorites' ? 'MAKE IT YOURS' : 'NO MATCHES';
    $('empty-text').textContent = category === 'favorites' ? 'Star an animation to keep it close. Try clearing your search.' : 'Try another name or reset the category filters.';
    for (const item of visible) {
      const card = document.createElement('article'); card.className = 'anim-card';
      const button = document.createElement('button'); button.type = 'button'; button.className = 'anim-card-select';
      button.dataset.animation = item.key; button.setAttribute('aria-pressed', String(item.key === selected));
      const eyebrow = document.createElement('span'); eyebrow.className = 'anim-card-meta'; eyebrow.textContent = item.categoryLabel;
      const title = document.createElement('strong'); title.textContent = item.label;
      const subtitle = document.createElement('small'); subtitle.textContent = item.variant + (item.isDefault ? ' · DEFAULT' : '');
      button.append(eyebrow, title, subtitle); button.addEventListener('click', () => select(item.key));
      const star = document.createElement('button'); star.type = 'button'; star.className = 'anim-star';
      star.textContent = favorites.has(item.key) ? '★' : '☆';
      star.setAttribute('aria-label', `Favourite ${item.label}, ${item.variant}`);
      star.setAttribute('aria-pressed', String(favorites.has(item.key)));
      star.addEventListener('click', () => {
        if (favorites.has(item.key)) favorites.delete(item.key); else favorites.add(item.key);
        save();
        if (category === 'favorites') { renderCards(); $('search').focus(); }
        else { star.textContent = favorites.has(item.key) ? '★' : '☆'; star.setAttribute('aria-pressed', String(favorites.has(item.key))); }
      });
      card.append(button, star); $('grid').append(card);
    }
    renderSelection();
  }
  function renderCurrent() {
    const steps = Array.isArray(current?.steps) ? current.steps : [];
    const step = steps[Number(current?.step) || 0];
    const action = items.find(x => x.profile === step?.profile && x.clip === step?.clip);
    $('status').textContent = busy ? 'REQUESTING ACTION…' : current?.active ? 'ACTIVE ACTION' : 'READY WHEN YOU ARE';
    $('current').textContent = current?.active ? (action ? `${action.label} · ${action.variant}` : step?.profile || 'Role-play action') : 'No active action';
    $('stop').disabled = !busy && !current?.active;
    $('current').closest('.anim-current').classList.toggle('active', busy || !!current?.active);
    renderSelection();
  }
  function open() {
    for (const tab of document.querySelectorAll('#freeroam-menu .tab')) tab.classList.toggle('active', tab.dataset.tab === 'animations');
    for (const page of document.querySelectorAll('#freeroam-menu .page')) page.classList.toggle('active', page.id === 'page-animations');
    $('search').focus({ preventScroll: true });
  }
  $('search').addEventListener('input', renderCards);
  $('reset').addEventListener('click', () => { category = 'all'; $('search').value = ''; renderFilters(); renderCards(); $('search').focus(); });
  $('loop').addEventListener('change', () => { $('duration-wrap').hidden = $('loop').checked; });
  $('stop').addEventListener('click', () => emit('stop'));
  $('play').addEventListener('click', () => {
    const item = items.find(x => x.key === selected);
    if (!item || busy) return;
    busy = true; renderCurrent();
    emit('play', { profile: item.profile, clip: item.clip, loop: $('loop').checked, durationMs: Number($('duration').value) });
  });
  Open77.on('animations:open', open);
  Open77.on('animations:state', state => {
    if (!state || typeof state !== 'object') return;
    const next = JSON.stringify(state.catalog || []);
    const loadChanged = loaded !== (state.loaded === true);
    loaded = state.loaded === true; busy = state.busy === true; current = state.current || null;
    if (next !== signature || loadChanged) {
      signature = next; items = model.entries(state.catalog);
      if (!items.some(x => x.key === selected)) selected = (items.find(x => x.tested) || items[0])?.key || '';
      renderCards();
    } else { $('total').textContent = loaded ? items.length : '—'; }
    $('message').textContent = String(state.message || ''); $('message').hidden = !state.message;
    renderCurrent();
  });
  renderFilters(); renderCards();
  Open77.emit('animations:ready', {});
})();

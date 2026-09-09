/* Pure catalogue projection, shared by the WebUI and Node regression tests. */
(function (root) {
  'use strict';
  const categories = { consumables: 'Consumables', social: 'Social', gestures: 'Gestures', relaxation: 'Relaxation', emotions: 'Emotions' };
  function variantName(clip, prefix) {
    const suffix = clip.startsWith(prefix) ? clip.slice(prefix.length) : clip;
    return suffix.replace(/^_+/, '').replace(/_+/g, ' ').trim().replace(/\b0+(\d+)\b/g, '$1')
      .replace(/^\w/, value => value.toUpperCase()) || 'Default';
  }
  function entries(catalog) {
    const result = [], seen = new Set();
    for (const profile of Array.isArray(catalog) ? catalog : []) {
      if (!profile || typeof profile.id !== 'string' || !Array.isArray(profile.clips)) continue;
      for (const [index, clip] of profile.clips.entries()) {
        if (typeof clip !== 'string') continue;
        const key = profile.id + ':' + clip;
        if (seen.has(key)) continue;
        seen.add(key);
        const isDefault = clip === profile.clip;
        result.push({ key, profile: profile.id, clip, label: String(profile.label || profile.id),
          category: profile.category || 'other', categoryLabel: categories[profile.category] || 'Other',
          variant: variantName(clip, profile.clipPrefix || ''), index: index + 1, isDefault,
          prop: profile.prop || '', placement: profile.placement || 'standing',
          tested: profile.id === 'smoke' && clip === 'stand__rh_cigarette__01__smoke__01' });
      }
    }
    return result;
  }
  function filter(items, category, query, favorites) {
    const needle = String(query || '').trim().toLowerCase();
    return items.filter(item => (category === 'all' || category === item.category ||
      (category === 'favorites' && favorites.has(item.key))) &&
      (!needle || `${item.label} ${item.profile} ${item.variant} ${item.categoryLabel} ${item.clip}`.toLowerCase().includes(needle)));
  }
  const api = { categories, entries, filter };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.FreeroamAnimationCatalog = api;
})(typeof window !== 'undefined' ? window : globalThis);

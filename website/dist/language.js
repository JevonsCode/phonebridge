(() => {
  const key = 'phonebridge.language';
  const current = document.documentElement.lang.startsWith('zh') ? 'zh' : 'en';
  let saved;
  try { saved = localStorage.getItem(key); } catch { /* Private browsing can deny storage. */ }
  const browserLanguage = navigator.languages?.[0] || navigator.language || 'en';
  const requested = new URL(location.href).searchParams.get('lang');
  const preferred = ['zh', 'en'].includes(requested) ? requested
    : ['zh', 'en'].includes(saved) ? saved
    : /^zh(?:-|$)/i.test(browserLanguage) ? 'zh' : 'en';
  // The English URL is an explicit entry. Only the root chooses automatically.
  if (current === 'zh' && preferred === 'en') {
    const destination = new URL('./en/', location.href);
    destination.search = location.search;
    destination.hash = location.hash;
    location.replace(destination.href);
  }
  document.addEventListener('DOMContentLoaded', () => {
    for (const link of document.querySelectorAll('[data-language]')) {
      const destination = new URL(link.href);
      destination.searchParams.set('lang', link.dataset.language);
      destination.hash = location.hash;
      link.href = destination.href;
      link.addEventListener('click', () => {
        const next = new URL(link.href);
        next.searchParams.set('lang', link.dataset.language);
        next.hash = location.hash;
        link.href = next.href;
        try { localStorage.setItem(key, link.dataset.language); } catch { /* Links still work. */ }
      });
    }
  });
})();

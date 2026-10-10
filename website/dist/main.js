const button = document.querySelector('#copy-command');
const english = document.documentElement.lang === 'en';
button.addEventListener('click', async () => {
  const status = document.querySelector('#copy-status');
  try {
    await navigator.clipboard.writeText(document.querySelector('#clone-command').textContent);
    button.textContent = english ? 'Copied ✓' : '已复制 ✓';
    status.textContent = english ? 'Instructions copied. Paste them into your AI assistant.' : '说明已复制，发给你的 AI 助手即可。';
  } catch {
    status.textContent = english ? 'Copy is unavailable. Select the instructions above and copy them manually.' : '浏览器未允许复制，请选择上方说明手动复制。';
  }
});

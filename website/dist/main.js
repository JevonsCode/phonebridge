const button = document.querySelector('#copy-command');
const english = document.documentElement.lang === 'en';
button.addEventListener('click', async () => {
  const status = document.querySelector('#copy-status');
  try {
    await navigator.clipboard.writeText(document.querySelector('#clone-command').textContent);
    button.textContent = english ? 'Copied ✓' : '已复制 ✓';
    status.textContent = english ? 'Command copied. Paste it into your computer’s terminal.' : '命令已复制，在电脑终端中粘贴即可。';
  } catch {
    status.textContent = english ? 'Copy is unavailable. Select the command above and copy it manually.' : '浏览器未允许复制，请选择上方命令手动复制。';
  }
});

const button = document.querySelector('#copy-command');
button.addEventListener('click', async () => {
  const status = document.querySelector('#copy-status');
  try {
    await navigator.clipboard.writeText(document.querySelector('#clone-command').textContent);
    button.textContent = '已复制 ✓';
    status.textContent = '命令已复制，在电脑终端中粘贴即可。';
  } catch {
    status.textContent = '浏览器未允许复制，请选择上方命令手动复制。';
  }
});

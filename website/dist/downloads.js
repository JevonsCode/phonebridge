(() => {
  const isEnglish = document.documentElement.lang === 'en';
  const localize = (zh, en) => isEnglish ? en : zh;
  const primary = document.getElementById('primary-download');
  const label = document.getElementById('download-label');
  const note = document.getElementById('device-note');
  const more = document.getElementById('all-downloads');
  const hints = navigator.userAgentData;
  const ua = navigator.userAgent || '';
  const platform = hints?.platform || navigator.platform || '';
  const mac = /Mac/i.test(platform) || /Macintosh/i.test(ua);
  let os;
  if (/iPad|iPhone|iPod|iOS/i.test(platform + ' ' + ua) || (mac && navigator.maxTouchPoints > 1)) os = 'ios';
  else if (/Android/i.test(platform + ' ' + ua)) os = 'android';
  else if (/CrOS/i.test(platform + ' ' + ua)) os = 'other';
  else if (/Windows/i.test(ua) || /^Win/i.test(platform)) os = 'windows';
  else if (mac) os = 'mac';
  else os = 'other';

  function showChoice(target, text, description = '') {
    primary.href = target;
    label.textContent = text;
    note.textContent = description;
    note.hidden = !description;
    if (target !== '#downloads') {
      more.href = '#downloads';
      more.textContent = localize('所有平台', 'All platforms');
    }
  }

  function recommend(id) {
    const installer = document.getElementById(id);
    showChoice(installer.href, installer.dataset.cta);
    installer.classList.add('recommended');
  }

  function showDownloads({architecture = '', bitness = '', wow64 = false} = {}) {
    if (os === 'mac') {
      if (/^arm(64)?$/i.test(architecture)) return recommend('mac-arm');
      if (/^x86(_64)?$/i.test(architecture)) return recommend('mac-intel');
      showChoice('#mac-downloads', localize('选择 Mac 芯片版本', 'Choose your Mac chip'),
        localize('打开苹果菜单  →「关于本机」，查看是 Apple 芯片还是 Intel。', 'Check Apple menu  → About This Mac for Apple silicon or Intel.'));
    } else if (os === 'windows') {
      if (/^arm/i.test(architecture) || /Windows (?:Phone|CE|RT)|ARM64|aarch64/i.test(ua) || (bitness === '32' && !wow64) || (/i[3-6]86/i.test(ua) && !/WOW64/i.test(ua))) {
        showChoice('#downloads', localize('查看可用版本', 'View available downloads'),
          localize('Windows 桌面安装包适用于 x64 电脑。', 'The Windows desktop installer is built for x64 PCs.'));
      } else {
        recommend('windows');
      }
    } else if (os === 'android') {
      if (/^x86/i.test(architecture) || bitness === '32') {
        showChoice('#downloads', localize('查看可用版本', 'View available downloads'),
          localize('安卓版支持 Android 11 及以上的 ARM64 设备。', 'The Android app requires Android 11 or later on an ARM64 device.'));
      } else {
        recommend('android');
      }
    } else if (os === 'ios') {
      showChoice('#downloads', localize('查看可用版本', 'View available downloads'),
        localize('目前手机端支持 Android，暂无 iOS 版。', 'The mobile app is available for Android. An iOS app is not available yet.'));
    }
  }

  // A Mac user agent may say Intel on Apple silicon. Only choose a DMG with explicit architecture data.
  if (os === 'mac' || os === 'windows' || os === 'android') {
    // While hints are pending, keep the chip chooser or the static platform list usable.
    if (os === 'mac') showDownloads();
    if (hints?.getHighEntropyValues) {
      hints.getHighEntropyValues(['architecture', 'bitness', 'wow64']).then(showDownloads, () => showDownloads());
    } else {
      showDownloads();
    }
  } else {
    showDownloads();
  }
})();

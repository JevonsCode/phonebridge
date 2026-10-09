# PhoneBridge website

Public site: https://phonebridge.jevons-code.chatgpt.site

`dist/` contains the complete static website. No Node dependencies or build step are required. Serve that directory with any static web server. The hosting identity and static directory are declared in `.openai/hosting.json`.

All illustrations are HTML/CSS/SVG, with no private device screenshots. The Chinese font is a WOFF2 subset of the app's Noto Sans SC font; its OFL license is included in `dist/OFL.txt`. When adding new text, regenerate the subset with FontTools and Brotli or use a system font fallback:

```text
python -m fontTools.subset mobile/assets/fonts/NotoSansSC.ttf --text-file=website/dist/index.html --output-file=website/dist/NotoSansSC.woff2 --flavor=woff2
```

The copy button uses the browser Clipboard API and shows a manual-copy fallback if permission is denied. The page has no analytics, accounts, or forms.

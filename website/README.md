# PhoneBridge website

Public site: https://xn--8ovp9s.xn--m8txu.com/phonebridge/ (有点.意思.com).

The website is hosted on GitHub Pages. The account's existing custom domain applies to this project site; `https://jevonscode.github.io/phonebridge/` also leads there. `.github/workflows/pages.yml` deploys only `website/dist/` when that directory changes on `main`, or when the workflow is run manually.

`dist/` contains the complete static website. No Node dependencies or build step are required. Serve that directory with any static web server. Assets use relative URLs so they work under the `/phonebridge/` project path.

The former `https://phonebridge.jevons-code.chatgpt.site` address serves only a permanent HTTP 301 redirect. Its separate source and hosting identity live in `legacy-redirect/`; never publish the main website to that host again. The redirect preserves paths and query strings, and browsers carry section fragments to the new location. Existing installed Android apps can continue using their old website link.

All illustrations are HTML/CSS/SVG, with no private device screenshots. The Chinese font is a WOFF2 subset of the app's Noto Sans SC font; its OFL license is included in `dist/OFL.txt`. When adding new text, regenerate the subset with FontTools and Brotli or use a system font fallback:

```text
python -m fontTools.subset mobile/assets/fonts/NotoSansSC.ttf --text-file=website/dist/index.html --output-file=website/dist/NotoSansSC.woff2 --flavor=woff2
```

The copy button uses the browser Clipboard API and shows a manual-copy fallback if permission is denied. The page has no analytics, accounts, or forms.

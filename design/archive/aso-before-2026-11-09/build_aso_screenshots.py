#!/usr/bin/env python3
import os
import subprocess

BASE_DIR = "/Users/ruslansabirov/Documents/ChatGPT/Plants/design/screenshots"
ASSETS_DIR = f"{BASE_DIR}/assets"
EN_DIR = f"{BASE_DIR}/en"
PL_DIR = f"{BASE_DIR}/pl"
HTML_DIR = "/tmp/narat_aso_v2_html"

os.makedirs(EN_DIR, exist_ok=True)
os.makedirs(PL_DIR, exist_ok=True)
os.makedirs(HTML_DIR, exist_ok=True)

CHROME_PATH = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# Unified Narat Brand Palette
# Primary Forest Green: #244D3C | Rich Forest Accent: #2E644E
# Warm Ivory: #F7F6F0 | Pale Sage: #E8EFE5 | Card Border: #E4E7E0
# Primary Text: #202923 | Secondary Text: #53635A
# Terracotta Alert: #C85A3B | Soft Terracotta: #F9EAE4

SVG_DROP = '<svg width="48" height="48" viewBox="0 0 24 24" fill="#2E644E"><path d="M12 2.69l5.66 5.66a8 8 0 1 1-11.31 0z"/></svg>'
SVG_DROP_LIGHT = '<svg width="48" height="48" viewBox="0 0 24 24" fill="#E8EFE5"><path d="M12 2.69l5.66 5.66a8 8 0 1 1-11.31 0z"/></svg>'
SVG_DROP_ALERT = '<svg width="56" height="56" viewBox="0 0 24 24" fill="#C85A3B"><path d="M12 2.69l5.66 5.66a8 8 0 1 1-11.31 0z"/></svg>'
SVG_PHOTO = '<svg width="52" height="52" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="M21 15l-5-5L5 21"/></svg>'
SVG_CAMERA = '<svg width="54" height="54" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/><circle cx="12" cy="13" r="4"/></svg>'
SVG_ARROWS = '<svg width="54" height="54" viewBox="0 0 24 24" fill="none" stroke="#202923" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"><path d="M17 8l4 4-4 4"/><path d="M7 16l-4-4 4-4"/><line x1="3" y1="12" x2="21" y2="12"/></svg>'
SVG_SEARCH = '<svg width="44" height="44" viewBox="0 0 24 24" fill="none" stroke="#244D3C" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>'
SVG_CLOCK = '<svg width="52" height="52" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>'
SVG_PLUS_BOX = '<svg width="52" height="52" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="4"/><line x1="12" y1="8" x2="12" y2="16"/><line x1="8" y1="12" x2="16" y2="12"/></svg>'
SVG_LEAF = '<svg width="52" height="52" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M11 20A7 7 0 0 1 9.8 6.1C15.5 5 17 4.48 19 2c1 2 2 4.18 2 8 0 5.5-4.78 10-10 10Z"/><path d="M2 21c0-3 1.85-5.36 5.08-6C9.5 14.52 12 13 13 12"/></svg>'
SVG_CLOUD = '<svg width="60" height="60" viewBox="0 0 24 24" fill="none" stroke="#53635A" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z"/></svg>'
SVG_SUN_CLOUD = '<svg width="68" height="68" viewBox="0 0 24 24" fill="none" stroke="#244D3C" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="M20 12h2"/><path d="m19.07 4.93-1.41 1.41"/><path d="M15.947 12.65a4 4 0 0 0-5.925-4.128"/><path d="M13 22H7a5 5 0 1 1 4.9-6H13a3 3 0 0 1 0 6Z"/></svg>'
SVG_SUN = '<svg width="60" height="60" viewBox="0 0 24 24" fill="none" stroke="#B96D50" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/></svg>'
SVG_GEAR = '<svg width="46" height="46" viewBox="0 0 24 24" fill="none" stroke="#53635A" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>'

COMMON_CSS = """
* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
  -webkit-font-smoothing: antialiased;
}
body {
  width: 1320px;
  height: 2868px;
  overflow: hidden;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
  position: relative;
  /* Unified Narat Deep Forest Green & Sage Botanical Canvas */
  background: linear-gradient(165deg, #2E614C 0%, #244D3C 48%, #183529 100%);
  color: #202923;
}
.bg-leaf-1 {
  position: absolute;
  top: -120px;
  left: -180px;
  width: 920px;
  height: 920px;
  border-radius: 0 80% 0 80%;
  background: radial-gradient(circle at 30% 30%, rgba(232, 239, 229, 0.14), rgba(232, 239, 229, 0.01) 70%);
  transform: rotate(-18deg);
  pointer-events: none;
}
.bg-leaf-2 {
  position: absolute;
  top: 220px;
  right: -240px;
  width: 1000px;
  height: 1000px;
  border-radius: 80% 0 80% 0;
  background: radial-gradient(circle at 60% 40%, rgba(10, 26, 19, 0.22), rgba(10, 26, 19, 0.0) 70%);
  transform: rotate(24deg);
  pointer-events: none;
}

/* Unified Massive 2-line Headline at Top (Warm Ivory #F7F6F0 on all 6 screens) */
.headline-wrap {
  position: absolute;
  top: 84px;
  left: 40px;
  right: 40px;
  height: 290px;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  text-align: center;
  z-index: 20;
}
.headline {
  font-size: 122px;
  font-weight: 900;
  line-height: 1.04;
  letter-spacing: -0.032em;
  color: #F7F6F0;
  text-shadow: 0 8px 28px rgba(8, 24, 17, 0.36);
}

/* Unified Giant Phone Frame */
.phone {
  position: absolute;
  top: 415px;
  left: 104px;
  width: 1112px;
  height: 2560px;
  background: #141C18;
  border-radius: 124px;
  padding: 26px;
  box-shadow: 0 40px 110px rgba(6, 22, 15, 0.52), 0 0 0 4px rgba(232, 239, 229, 0.22);
  z-index: 5;
}
.phone-screen {
  width: 100%;
  height: 100%;
  background: #F7F6F0;
  border-radius: 98px;
  overflow: hidden;
  position: relative;
}
.notch {
  position: absolute;
  top: 28px;
  left: 50%;
  transform: translateX(-50%);
  width: 260px;
  height: 70px;
  background: #0D120F;
  border-radius: 40px;
  z-index: 30;
}

/* Unified Pop-out Card that breaks outside phone bezel */
.pop-card {
  position: absolute;
  left: 44px;
  width: 1232px;
  background: #FFFFFF;
  border: 3px solid #E4E7E0;
  border-radius: 46px;
  box-shadow: 0 36px 90px rgba(8, 24, 17, 0.44), 0 6px 20px rgba(8, 24, 17, 0.18);
  z-index: 40;
}
"""

def build_screen_1(lang):
  if lang == "en":
    h1, h2 = "Yellowing Leaves?", "First Help"
    target_txt = "Overwatering"
    card_title = "Waterlogged Soil"
    card_sub = "Check soil 5 cm deep"
    btn_txt = "Save"
    cam_left, cam_right = "Photos", "3 Questions"
  else:
    h1, h2 = "Żółkną liście?", "Pierwsza pomoc"
    target_txt = "Przelanie"
    card_title = "Mokra ziemia"
    card_sub = "Sprawdź ziemię na 5 cm"
    btn_txt = "Ratuj"
    cam_left, cam_right = "Zdjęcia", "3 pytania"

  return f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>{COMMON_CSS}
.cam-photo {{
  position: absolute;
  top: 0; left: 0; right: 0; height: 1960px;
  background: #1A241E;
  overflow: hidden;
}}
.cam-photo img.bg-leaf {{
  width: 100%;
  height: 100%;
  object-fit: cover;
  filter: saturate(1.08) contrast(1.05);
}}
.scan-corner {{
  position: absolute;
  width: 110px;
  height: 110px;
  border-color: rgba(247, 246, 240, 0.90);
  border-style: solid;
  z-index: 15;
}}
.sc-tl {{ top: 160px; left: 74px; border-width: 12px 0 0 12px; border-top-left-radius: 36px; }}
.sc-tr {{ top: 160px; right: 74px; border-width: 12px 12px 0 0; border-top-right-radius: 36px; }}
.sc-bl {{ top: 1320px; left: 74px; border-width: 0 0 12px 12px; border-bottom-left-radius: 36px; }}
.sc-br {{ top: 1320px; right: 74px; border-width: 0 12px 12px 0; border-bottom-right-radius: 36px; }}

.target-ring {{
  position: absolute;
  top: 600px;
  left: 50%;
  transform: translateX(-50%);
  width: 560px;
  height: 560px;
  border-radius: 50%;
  border: 14px solid #C85A3B;
  background: radial-gradient(circle, rgba(200,90,59,0.22) 0%, rgba(200,90,59,0.06) 70%);
  box-shadow: 0 0 0 8px rgba(200,90,59,0.26), 0 24px 60px rgba(0,0,0,0.45);
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  z-index: 20;
}}
.warn-triangle {{
  width: 154px;
  height: 140px;
  background: #C85A3B;
  clip-path: polygon(50% 6%, 4% 94%, 96% 94%);
  display: flex;
  align-items: flex-end;
  justify-content: center;
  padding-bottom: 18px;
  color: #F7F6F0;
  font-size: 86px;
  font-weight: 900;
  margin-bottom: 24px;
  filter: drop-shadow(0 10px 20px rgba(0,0,0,0.3));
}}
.target-pill {{
  position: absolute;
  bottom: -46px;
  background: #C85A3B;
  color: #F7F6F0;
  font-size: 62px;
  font-weight: 900;
  padding: 24px 64px;
  border-radius: 64px;
  white-space: nowrap;
  box-shadow: 0 18px 40px rgba(200, 90, 59, 0.50);
  letter-spacing: -0.02em;
}}

.diag-pop {{
  top: 1850px;
  padding: 44px 50px;
  display: flex;
  align-items: center;
  justify-content: space-between;
}}
.diag-left {{
  display: flex;
  align-items: center;
  gap: 36px;
}}
.aid-box {{
  width: 132px;
  height: 132px;
  border-radius: 36px;
  background: #F9EAE4;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}}
.aid-icon {{
  width: 78px;
  height: 66px;
  background: #C85A3B;
  border-radius: 14px;
  position: relative;
  display: flex;
  align-items: center;
  justify-content: center;
  color: #F7F6F0;
  font-size: 52px;
  font-weight: 900;
}}
.aid-icon::before {{
  content: "";
  position: absolute;
  top: -14px;
  width: 34px;
  height: 14px;
  border: 6px solid #C85A3B;
  border-bottom: none;
  border-radius: 10px 10px 0 0;
}}
.diag-title {{
  font-size: 60px;
  font-weight: 900;
  color: #202923;
  letter-spacing: -0.02em;
  line-height: 1.1;
}}
.diag-sub {{
  font-size: 42px;
  font-weight: 700;
  color: #53635A;
  margin-top: 8px;
}}
.cure-btn {{
  background: #244D3C;
  color: #F7F6F0;
  font-size: 54px;
  font-weight: 900;
  padding: 34px 68px;
  border-radius: 68px;
  box-shadow: 0 16px 36px rgba(36, 77, 60, 0.38);
  white-space: nowrap;
}}

/* Camera bottom bar placed cleanly inside visible 2868px frame */
.cam-bar {{
  position: absolute;
  top: 1940px;
  left: 0;
  right: 0;
  height: 550px;
  background: #18221D;
  display: flex;
  align-items: center;
  justify-content: space-around;
  padding: 60px 80px 80px;
  z-index: 25;
}}
.cam-side {{
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 18px;
  color: #E8EFE5;
  font-size: 40px;
  font-weight: 800;
}}
.cam-circle {{
  width: 118px;
  height: 118px;
  border-radius: 50%;
  background: rgba(232, 239, 229, 0.14);
  display: flex;
  align-items: center;
  justify-content: center;
  color: #F7F6F0;
}}
.shutter {{
  width: 190px;
  height: 190px;
  border-radius: 50%;
  border: 10px solid #F7F6F0;
  padding: 12px;
  display: flex;
  align-items: center;
  justify-content: center;
}}
.shutter-inner {{
  width: 100%;
  height: 100%;
  border-radius: 50%;
  background: #2E644E;
}}
</style></head>
<body>
  <div class="bg-leaf-1"></div>
  <div class="bg-leaf-2"></div>
  <div class="headline-wrap">
    <div class="headline">{h1}<br>{h2}</div>
  </div>

  <div class="phone">
    <div class="phone-screen">
      <div class="notch"></div>
      <div class="cam-photo">
        <img class="bg-leaf" src="file://{ASSETS_DIR}/yellow_leaves_clean.png">
        <div class="scan-corner sc-tl"></div>
        <div class="scan-corner sc-tr"></div>
        <div class="scan-corner sc-bl"></div>
        <div class="scan-corner sc-br"></div>

        <div class="target-ring">
          <div class="warn-triangle">!</div>
          <div class="target-pill">{target_txt}</div>
        </div>
      </div>

      <div class="cam-bar">
        <div class="cam-side">
          <div class="cam-circle">{SVG_PHOTO}</div>
          <span>{cam_left}</span>
        </div>
        <div class="shutter"><div class="shutter-inner"></div></div>
        <div class="cam-side">
          <div class="cam-circle">{SVG_DROP_LIGHT}</div>
          <span>{cam_right}</span>
        </div>
      </div>
    </div>
  </div>

  <div class="pop-card diag-pop">
    <div class="diag-left">
      <div class="aid-box"><div class="aid-icon">+</div></div>
      <div>
        <div class="diag-title">{card_title}</div>
        <div class="diag-sub">{card_sub}</div>
      </div>
    </div>
    <div class="cure-btn">{btn_txt}</div>
  </div>
</body></html>"""


def build_screen_2(lang):
  if lang == "en":
    h1, h2 = "Step-by-Step", "Recovery Plan"
    before_txt, after_txt = "Before", "After"
    diag_title = "Overwatering Risk"
    diag_desc = "Pause watering now & let the top 5 cm of soil dry out completely."
    sym_title = "Symptoms & First Steps"
    p1, p2 = "✓ Yellow leaves", "✓ Wet soil"
    p3, p4 = "✓ Pause watering", "✓ Check in 14d"
    cta_txt = "Start 14-Day Recovery Plan"
  else:
    h1, h2 = "Plan ratunku", "krok po kroku"
    before_txt, after_txt = "Przed", "Po"
    diag_title = "Ryzyko przelania"
    diag_desc = "Wstrzymaj podlewanie i pozwól górnym 5 cm ziemi przeschnąć."
    sym_title = "Objawy i pierwsze kroki"
    p1, p2 = "✓ Żółte liście", "✓ Mokra ziemia"
    p3, p4 = "✓ Stop wody", "✓ Kontrola 14d"
    cta_txt = "Rozpocznij plan 14 dni"

  return f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>{COMMON_CSS}
.hero-split {{
  position: relative;
  width: 100%;
  height: 1020px;
  display: flex;
  overflow: hidden;
  background: #141E18;
}}
.split-half {{
  width: 50%;
  height: 100%;
  position: relative;
  overflow: hidden;
}}
.split-half img {{
  width: 100%;
  height: 100%;
  object-fit: cover;
}}
.split-divider {{
  position: absolute;
  top: 0; bottom: 0; left: 50%;
  width: 10px;
  background: #F7F6F0;
  transform: translateX(-50%);
  z-index: 15;
}}
.split-knob {{
  position: absolute;
  top: 52%;
  left: 50%;
  transform: translate(-50%, -50%);
  width: 124px;
  height: 124px;
  border-radius: 50%;
  background: #F7F6F0;
  box-shadow: 0 12px 34px rgba(0,0,0,0.4);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 20;
}}
.ba-label {{
  position: absolute;
  top: 52%;
  transform: translateY(-50%);
  background: rgba(20, 28, 24, 0.82);
  color: #F7F6F0;
  font-size: 48px;
  font-weight: 900;
  padding: 18px 42px;
  border-radius: 40px;
  z-index: 18;
  backdrop-filter: blur(8px);
}}
.ba-left {{ left: 48px; }}
.ba-right {{ right: 48px; }}

.content-area {{
  padding: 52px 60px;
  background: #F7F6F0;
  height: 1460px;
}}
.disease-h {{
  font-size: 68px;
  font-weight: 900;
  color: #202923;
  letter-spacing: -0.025em;
  margin-bottom: 20px;
}}
.disease-p {{
  font-size: 46px;
  font-weight: 700;
  line-height: 1.3;
  color: #53635A;
}}
.sym-heading {{
  font-size: 52px;
  font-weight: 900;
  color: #202923;
  margin-top: 42px;
}}

.pills-pop {{
  top: 1835px;
  padding: 52px 54px;
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 32px;
}}
.sym-pill {{
  height: 130px;
  border-radius: 65px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 46px;
  font-weight: 900;
  letter-spacing: -0.015em;
  padding: 0 34px;
  white-space: nowrap;
}}
.pill-red-solid {{
  background: #C85A3B;
  color: #F7F6F0;
  box-shadow: 0 16px 34px rgba(200, 90, 59, 0.32);
}}
.pill-red-soft {{
  background: #F9EAE4;
  color: #A8462B;
}}
.pill-green-solid {{
  background: #244D3C;
  color: #F7F6F0;
  box-shadow: 0 16px 34px rgba(36, 77, 60, 0.32);
}}
.pill-green-soft {{
  background: #E8EFE5;
  color: #244D3C;
}}

.bottom-cta {{
  margin-top: 520px;
  height: 144px;
  background: #244D3C;
  border-radius: 72px;
  display: flex;
  align-items: center;
  justify-content: center;
  color: #F7F6F0;
  font-size: 50px;
  font-weight: 900;
  box-shadow: 0 20px 44px rgba(36, 77, 60, 0.35);
}}
</style></head>
<body>
  <div class="bg-leaf-1"></div>
  <div class="bg-leaf-2"></div>
  <div class="headline-wrap">
    <div class="headline">{h1}<br>{h2}</div>
  </div>

  <div class="phone">
    <div class="phone-screen">
      <div class="notch"></div>
      <div class="hero-split">
        <div class="split-half">
          <img src="file://{ASSETS_DIR}/yellow_leaves_clean.png">
        </div>
        <div class="split-half">
          <img src="file://{ASSETS_DIR}/fiddle_clean.png">
        </div>
        <div class="split-divider"></div>
        <div class="ba-label ba-left">{before_txt}</div>
        <div class="ba-label ba-right">{after_txt}</div>
        <div class="split-knob">{SVG_ARROWS}</div>
      </div>

      <div class="content-area">
        <div class="disease-h">{diag_title}</div>
        <div class="disease-p">{diag_desc}</div>
        <div class="sym-heading">{sym_title}</div>
        <div class="bottom-cta">{cta_txt}</div>
      </div>
    </div>
  </div>

  <div class="pop-card pills-pop">
    <div class="sym-pill pill-red-solid">{p1}</div>
    <div class="sym-pill pill-red-soft">{p2}</div>
    <div class="sym-pill pill-green-solid">{p3}</div>
    <div class="sym-pill pill-green-soft">{p4}</div>
  </div>
</body></html>"""


def build_screen_3(lang):
  if lang == "en":
    h1, h2 = "Set Smart", "Reminders"
    days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    water_h = "Water"
    water_badge = "If top 5 cm dry"
    p1_name, p1_room = "Monstera", "Living room"
    btn_txt = "Complete"
    next_h = "Soil Check & Care"
    p2_name, p2_room = "Fiddle-leaf fig", "Bedroom"
    p3_name, p3_room = "Peace lily", "Balcony"
    p4_name, p4_room = "Snake plant", "Office"
    tabs = ["Schedule", "Diagnose", "Find Plant", "My Plants"]
  else:
    h1, h2 = "Mądre", "przypomnienia"
    days = ["Nd", "Pon", "Wt", "Śr", "Czw", "Pt", "Sob"]
    water_h = "Podlewanie"
    water_badge = "Gdy 5 cm suche"
    p1_name, p1_room = "Monstera", "Salon"
    btn_txt = "Gotowe"
    next_h = "Kolejne zadania"
    p2_name, p2_room = "Fikus lirolistny", "Sypialnia"
    p3_name, p3_room = "Skrzydłokwiat", "Balkon"
    p4_name, p4_room = "Sansewieria", "Biuro"
    tabs = ["Zadania", "Diagnoza", "Katalog", "Rośliny"]

  days_html = ""
  nums = [6, 7, 8, 9, 10, 11, 12]
  for d, n in zip(days, nums):
    active = "active" if n == 8 else ""
    days_html += f'<div class="day-col"><span class="day-name">{d}</span><div class="day-num {active}">{n}</div></div>'

  return f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>{COMMON_CSS}
.week-strip {{
  padding: 132px 54px 38px;
  background: #FFFFFF;
  display: flex;
  justify-content: space-between;
  border-bottom: 3px solid #E4E7E0;
}}
.day-col {{
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 18px;
}}
.day-name {{
  font-size: 36px;
  font-weight: 700;
  color: #53635A;
}}
.day-num {{
  width: 92px;
  height: 92px;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 44px;
  font-weight: 900;
  color: #202923;
}}
.day-num.active {{
  background: #244D3C;
  color: #F7F6F0;
  box-shadow: 0 12px 26px rgba(36, 77, 60, 0.30);
}}

.water-pop {{
  top: 785px;
  padding: 46px 54px;
}}
.water-top {{
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 32px;
}}
.water-title {{
  display: flex;
  align-items: center;
  gap: 20px;
  font-size: 56px;
  font-weight: 900;
  color: #202923;
}}
.water-SubPill {{
  background: #E8EFE5;
  color: #244D3C;
  font-size: 38px;
  font-weight: 800;
  padding: 16px 36px;
  border-radius: 40px;
}}
.water-row {{
  display: flex;
  align-items: center;
  justify-content: space-between;
}}
.plant-info {{
  display: flex;
  align-items: center;
  gap: 32px;
}}
.plant-thumb {{
  width: 192px;
  height: 192px;
  border-radius: 36px;
  object-fit: cover;
  background: #E8EFE5;
}}
.plant-name {{
  font-size: 56px;
  font-weight: 900;
  color: #202923;
  letter-spacing: -0.02em;
}}
.plant-room {{
  font-size: 42px;
  font-weight: 700;
  color: #53635A;
  margin-top: 8px;
}}
.complete-wrap {{
  position: relative;
  display: flex;
  align-items: center;
  justify-content: center;
}}
.complete-btn {{
  background: #244D3C;
  color: #F7F6F0;
  font-size: 48px;
  font-weight: 900;
  padding: 32px 64px;
  border-radius: 64px;
  box-shadow: 0 16px 36px rgba(36, 77, 60, 0.36);
  position: relative;
  z-index: 2;
}}
.ray {{
  position: absolute;
  width: 26px;
  height: 10px;
  border-radius: 6px;
}}
.r1 {{ top: -38px; left: 25%; background: #D99B26; transform: rotate(65deg); }}
.r2 {{ top: -42px; left: 55%; background: #C85A3B; transform: rotate(105deg); }}
.r3 {{ top: -24px; right: -24px; background: #2E644E; transform: rotate(145deg); }}
.r4 {{ bottom: -36px; left: 28%; background: #C85A3B; transform: rotate(-65deg); }}
.r5 {{ bottom: -40px; left: 58%; background: #2E644E; transform: rotate(-105deg); }}
.r6 {{ bottom: -22px; right: -26px; background: #D99B26; transform: rotate(-145deg); }}

.lower-section {{
  margin: 515px 44px 0;
  background: #FFFFFF;
  border: 2px solid #E4E7E0;
  border-radius: 44px;
  padding: 42px 44px;
  box-shadow: 0 14px 40px rgba(0,0,0,0.05);
}}
.lower-h {{
  font-size: 48px;
  font-weight: 900;
  color: #202923;
  margin-bottom: 24px;
  display: flex;
  align-items: center;
  gap: 18px;
}}
.sub-row {{
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 24px 0;
  border-top: 2px solid #E8EFE5;
}}
.sub-thumb {{
  width: 146px;
  height: 146px;
  border-radius: 28px;
  object-fit: cover;
}}
.sub-name {{
  font-size: 46px;
  font-weight: 900;
  color: #202923;
}}
.sub-room {{
  font-size: 38px;
  font-weight: 700;
  color: #53635A;
  margin-top: 6px;
}}
.sub-btn {{
  background: #E8EFE5;
  color: #244D3C;
  font-size: 40px;
  font-weight: 900;
  padding: 24px 46px;
  border-radius: 50px;
}}

/* Tab bar positioned at top: 2210px so 100% visible inside 2868px canvas */
.tab-bar {{
  position: absolute;
  top: 2210px;
  left: 0; right: 0;
  height: 220px;
  background: #FFFFFF;
  border-top: 3px solid #E4E7E0;
  display: flex;
  justify-content: space-around;
  align-items: center;
  padding: 0 30px 10px;
  z-index: 25;
}}
.tab-item {{
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 12px;
  font-size: 34px;
  font-weight: 800;
  color: #53635A;
}}
.tab-item.active {{
  color: #244D3C;
}}
</style></head>
<body>
  <div class="bg-leaf-1"></div>
  <div class="bg-leaf-2"></div>
  <div class="headline-wrap">
    <div class="headline">{h1}<br>{h2}</div>
  </div>

  <div class="phone">
    <div class="phone-screen">
      <div class="notch"></div>
      <div class="week-strip">{days_html}</div>

      <div class="lower-section">
        <div class="lower-h">{SVG_LEAF} <span>{next_h}</span></div>
        <div class="sub-row">
          <div class="plant-info">
            <img class="sub-thumb" src="file://{ASSETS_DIR}/fiddle_clean.png">
            <div>
              <div class="sub-name">{p2_name}</div>
              <div class="sub-room">{p2_room}</div>
            </div>
          </div>
          <div class="sub-btn">{btn_txt}</div>
        </div>
        <div class="sub-row">
          <div class="plant-info">
            <img class="sub-thumb" src="file://{ASSETS_DIR}/peace_lily_pot.png">
            <div>
              <div class="sub-name">{p3_name}</div>
              <div class="sub-room">{p3_room}</div>
            </div>
          </div>
          <div class="sub-btn">{btn_txt}</div>
        </div>
        <div class="sub-row">
          <div class="plant-info">
            <img class="sub-thumb" src="file://{ASSETS_DIR}/snake_plant_pot.png">
            <div>
              <div class="sub-name">{p4_name}</div>
              <div class="sub-room">{p4_room}</div>
            </div>
          </div>
          <div class="sub-btn">{btn_txt}</div>
        </div>
      </div>

      <div class="tab-bar">
        <div class="tab-item active">{SVG_CLOCK}<span>{tabs[0]}</span></div>
        <div class="tab-item">{SVG_PLUS_BOX}<span>{tabs[1]}</span></div>
        <div class="tab-item">{SVG_SEARCH}<span>{tabs[2]}</span></div>
        <div class="tab-item">{SVG_LEAF}<span>{tabs[3]}</span></div>
      </div>
    </div>
  </div>

  <div class="pop-card water-pop">
    <div class="water-top">
      <div class="water-title">{SVG_DROP} <span>{water_h}</span></div>
      <div class="water-SubPill">{water_badge}</div>
    </div>
    <div class="water-row">
      <div class="plant-info">
        <img class="plant-thumb" src="file://{ASSETS_DIR}/monstera_pot.png">
        <div>
          <div class="plant-name">{p1_name}</div>
          <div class="plant-room">{p1_room}</div>
        </div>
      </div>
      <div class="complete-wrap">
        <div class="ray r1"></div><div class="ray r2"></div><div class="ray r3"></div>
        <div class="ray r4"></div><div class="ray r5"></div><div class="ray r6"></div>
        <div class="complete-btn">{btn_txt}</div>
      </div>
    </div>
  </div>
</body></html>"""


def build_screen_4(lang):
  if lang == "en":
    h1, h2 = "Identify &", "Care Plants"
    sp_name, sp_latin = "Peace lily", "Spathiphyllum wallisii"
    match_txt = "✓ Likely Match"
    tip_b, tip_t = "Care rule:", "Check soil 5 cm deep first — water only when the top layer feels dry."
    cat_badge = "300+ Indoor Plants Catalogue"
    c1_name, c1_sub = "Monstera deliciosa", "Swiss Cheese Plant"
    c2_name, c2_sub = "Ficus elastica", "Rubber Plant"
  else:
    h1, h2 = "Rozpoznaj", "i pielęgnuj"
    sp_name, sp_latin = "Skrzydłokwiat", "Spathiphyllum wallisii"
    match_txt = "✓ Dopasowano"
    tip_b, tip_t = "Zasada:", "Sprawdzaj ziemię na 5 cm — podlewaj tylko gdy górna warstwa przeschnie."
    cat_badge = "Katalog 300 gatunków domowych"
    c1_name, c1_sub = "Monstera dziurawa", "Monstera deliciosa"
    c2_name, c2_sub = "Fikus sprężysty", "Ficus elastica"

  return f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>{COMMON_CSS}
.id-pop {{
  top: 425px;
  padding: 48px 54px;
}}
.id-header {{
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 36px;
}}
.id-left {{
  display: flex;
  align-items: center;
  gap: 36px;
}}
.id-photo {{
  width: 204px;
  height: 204px;
  border-radius: 38px;
  object-fit: cover;
}}
.id-title {{
  font-size: 64px;
  font-weight: 900;
  color: #202923;
  letter-spacing: -0.025em;
}}
.id-latin {{
  font-size: 42px;
  font-weight: 600;
  font-style: italic;
  color: #53635A;
  margin-top: 8px;
}}
.match-pill {{
  background: #E8EFE5;
  color: #244D3C;
  font-size: 36px;
  font-weight: 900;
  padding: 16px 32px;
  border-radius: 36px;
  white-space: nowrap;
}}
.tip-box {{
  border: 4px solid #244D3C;
  background: #E8EFE5;
  border-radius: 34px;
  padding: 32px 40px;
  font-size: 44px;
  line-height: 1.32;
  font-weight: 700;
  color: #202923;
}}
.tip-box strong {{
  font-weight: 900;
  color: #244D3C;
}}

.phone-low {{
  top: 1050px;
  height: 1920px;
}}
.cat-wrap {{
  padding: 132px 52px 52px;
}}
.cat-search {{
  background: #FFFFFF;
  border: 3px solid #E4E7E0;
  border-radius: 56px;
  padding: 28px 44px;
  font-size: 42px;
  font-weight: 900;
  color: #202923;
  margin-bottom: 38px;
  display: flex;
  align-items: center;
  gap: 20px;
  box-shadow: 0 12px 30px rgba(0,0,0,0.05);
}}
.cat-card {{
  position: relative;
  height: 640px;
  border-radius: 46px;
  overflow: hidden;
  margin-bottom: 38px;
  box-shadow: 0 20px 50px rgba(0,0,0,0.14);
}}
.cat-card img {{
  width: 100%;
  height: 100%;
  object-fit: cover;
}}
.cat-overlay {{
  position: absolute;
  left: 0; right: 0; bottom: 0;
  padding: 60px 44px 38px;
  background: linear-gradient(to top, rgba(16, 30, 23, 0.90) 0%, rgba(16, 30, 23, 0.0) 100%);
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
}}
.cat-name {{
  font-size: 56px;
  font-weight: 900;
  color: #F7F6F0;
}}
.cat-sub {{
  font-size: 40px;
  font-weight: 700;
  color: rgba(247, 246, 240, 0.85);
  margin-top: 6px;
}}
.add-circle {{
  width: 112px;
  height: 112px;
  border-radius: 50%;
  background: #244D3C;
  border: 3px solid rgba(247, 246, 240, 0.4);
  color: #F7F6F0;
  font-size: 68px;
  font-weight: 900;
  display: flex;
  align-items: center;
  justify-content: center;
  box-shadow: 0 12px 28px rgba(0,0,0,0.35);
}}
</style></head>
<body>
  <div class="bg-leaf-1"></div>
  <div class="bg-leaf-2"></div>
  <div class="headline-wrap">
    <div class="headline">{h1}<br>{h2}</div>
  </div>

  <div class="pop-card id-pop">
    <div class="id-header">
      <div class="id-left">
        <img class="id-photo" src="file://{ASSETS_DIR}/peace_lily_pot.png">
        <div>
          <div class="id-title">{sp_name}</div>
          <div class="id-latin">{sp_latin}</div>
        </div>
      </div>
      <div class="match-pill">{match_txt}</div>
    </div>
    <div class="tip-box">
      <strong>{tip_b}</strong> {tip_t}
    </div>
  </div>

  <div class="phone phone-low">
    <div class="phone-screen">
      <div class="notch"></div>
      <div class="cat-wrap">
        <div class="cat-search">{SVG_SEARCH} <span>{cat_badge}</span></div>

        <div class="cat-card">
          <img src="file://{ASSETS_DIR}/monstera_leaf.png">
          <div class="cat-overlay">
            <div>
              <div class="cat-name">{c1_name}</div>
              <div class="cat-sub">{c1_sub}</div>
            </div>
            <div class="add-circle">+</div>
          </div>
        </div>

        <div class="cat-card">
          <img src="file://{ASSETS_DIR}/rubber_clean.png">
          <div class="cat-overlay">
            <div>
              <div class="cat-name">{c2_name}</div>
              <div class="cat-sub">{c2_sub}</div>
            </div>
            <div class="add-circle">+</div>
          </div>
        </div>
      </div>
    </div>
  </div>
</body></html>"""


def build_screen_5(lang):
  if lang == "en":
    h1, h2 = "Tailored to", "Your Room"
    step_badge = "3 Quick Questions"
    q_title = "What light does your room get?"
    opt1_t, opt1_s = "Low Light", "Shaded room or far from window"
    opt2_t, opt2_s = "Bright Indirect", "Near window, no harsh sun"
    opt2_pill = "✓ Optimal for Monstera"
    opt3_t, opt3_s = "Direct Sun", "Bright south-facing window"
    cam_t, cam_s = "Check Light with Camera", "Instant room light estimate"
    q23_pills = ["✓ Pot with drainage", "✓ Watered 5 days ago"]
    btn_continue = "Continue  →"
  else:
    h1, h2 = "Dopasowane do", "Twojego pokoju"
    step_badge = "3 szybkie pytania"
    q_title = "Jakie światło jest w pokoju?"
    opt1_t, opt1_s = "Słabe światło", "Z dala od okna lub cień"
    opt2_t, opt2_s = "Jasne rozproszone", "Blisko okna, bez ostrego słońca"
    opt2_pill = "✓ Idealne dla Monstery"
    opt3_t, opt3_s = "Pełne słońce", "Bezpośrednie promienie słoneczne"
    cam_t, cam_s = "Zmierz światło aparatem", "Szybka ocena światła w pokoju"
    q23_pills = ["✓ Doniczka z odpływem", "✓ Podlane 5 dni temu"]
    btn_continue = "Dalej  →"

  return f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>{COMMON_CSS}
.q-wrap {{
  padding: 132px 56px 50px;
}}
.q-badge {{
  display: inline-flex;
  align-items: center;
  gap: 14px;
  background: #E8EFE5;
  color: #244D3C;
  font-size: 38px;
  font-weight: 900;
  padding: 16px 38px;
  border-radius: 40px;
  margin-bottom: 24px;
}}
.q-heading {{
  font-size: 64px;
  font-weight: 900;
  color: #202923;
  line-height: 1.12;
  letter-spacing: -0.025em;
  margin-bottom: 36px;
}}
.opt-card {{
  background: #FFFFFF;
  border: 2px solid #E4E7E0;
  border-radius: 40px;
  padding: 40px 44px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 34px;
  box-shadow: 0 12px 32px rgba(0,0,0,0.04);
}}
.opt-left {{
  display: flex;
  align-items: center;
  gap: 34px;
}}
.opt-icon {{
  width: 120px;
  height: 120px;
  border-radius: 34px;
  background: #F7F6F0;
  display: flex;
  align-items: center;
  justify-content: center;
}}
.opt-title {{
  font-size: 52px;
  font-weight: 900;
  color: #202923;
}}
.opt-sub {{
  font-size: 38px;
  font-weight: 700;
  color: #53635A;
  margin-top: 8px;
}}
.radio-circle {{
  width: 72px;
  height: 72px;
  border-radius: 50%;
  border: 6px solid #CFD9D2;
}}

.opt-pop {{
  top: 1095px;
  padding: 44px 54px;
  border: 8px solid #244D3C;
  display: flex;
  align-items: center;
  justify-content: space-between;
}}
.opt-pop .opt-icon {{
  width: 138px;
  height: 138px;
  background: #E8EFE5;
}}
.opt-pop .opt-title {{
  font-size: 58px;
}}
.opt-pill {{
  display: inline-block;
  margin-top: 14px;
  background: #244D3C;
  color: #F7F6F0;
  font-size: 36px;
  font-weight: 900;
  padding: 12px 32px;
  border-radius: 32px;
}}
.check-circle {{
  width: 96px;
  height: 96px;
  border-radius: 50%;
  background: #244D3C;
  color: #F7F6F0;
  font-size: 54px;
  font-weight: 900;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}}

.spacer-pop {{
  height: 390px;
}}

.cam-card {{
  margin-top: 34px;
  background: #244D3C;
  border-radius: 42px;
  padding: 42px 48px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  color: #F7F6F0;
  box-shadow: 0 20px 48px rgba(36, 77, 60, 0.25);
}}
.cam-card .opt-icon {{
  background: rgba(232, 239, 229, 0.16);
  color: #F7F6F0;
}}
.cam-card .opt-title {{
  color: #F7F6F0;
  font-size: 48px;
}}
.cam-card .opt-sub {{
  color: #E8EFE5;
}}

.q23-row {{
  display: flex;
  gap: 24px;
  margin-top: 34px;
}}
.q23-chip {{
  flex: 1;
  background: #E8EFE5;
  color: #244D3C;
  font-size: 36px;
  font-weight: 800;
  padding: 24px 28px;
  border-radius: 32px;
  text-align: center;
}}

.continue-btn {{
  margin-top: 36px;
  height: 148px;
  background: #244D3C;
  border-radius: 74px;
  display: flex;
  align-items: center;
  justify-content: center;
  color: #F7F6F0;
  font-size: 54px;
  font-weight: 900;
  box-shadow: 0 20px 44px rgba(36, 77, 60, 0.35);
}}
</style></head>
<body>
  <div class="bg-leaf-1"></div>
  <div class="bg-leaf-2"></div>
  <div class="headline-wrap">
    <div class="headline">{h1}<br>{h2}</div>
  </div>

  <div class="phone">
    <div class="phone-screen">
      <div class="notch"></div>
      <div class="q-wrap">
        <div class="q-badge">{step_badge}</div>
        <div class="q-heading">{q_title}</div>

        <div class="opt-card">
          <div class="opt-left">
            <div class="opt-icon">{SVG_CLOUD}</div>
            <div>
              <div class="opt-title">{opt1_t}</div>
              <div class="opt-sub">{opt1_s}</div>
            </div>
          </div>
          <div class="radio-circle"></div>
        </div>

        <div class="spacer-pop"></div>

        <div class="opt-card">
          <div class="opt-left">
            <div class="opt-icon">{SVG_SUN}</div>
            <div>
              <div class="opt-title">{opt3_t}</div>
              <div class="opt-sub">{opt3_s}</div>
            </div>
          </div>
          <div class="radio-circle"></div>
        </div>

        <div class="cam-card">
          <div class="opt-left">
            <div class="opt-icon">{SVG_CAMERA}</div>
            <div>
              <div class="opt-title">{cam_t}</div>
              <div class="opt-sub">{cam_s}</div>
            </div>
          </div>
          <div class="check-circle" style="background:#2E644E;">→</div>
        </div>

        <div class="q23-row">
          <div class="q23-chip">{q23_pills[0]}</div>
          <div class="q23-chip">{q23_pills[1]}</div>
        </div>

        <div class="continue-btn">{btn_continue}</div>
      </div>
    </div>
  </div>

  <div class="pop-card opt-pop">
    <div class="opt-left">
      <div class="opt-icon">{SVG_SUN_CLOUD}</div>
      <div>
        <div class="opt-title">{opt2_t}</div>
        <div class="opt-sub">{opt2_s}</div>
        <div class="opt-pill">{opt2_pill}</div>
      </div>
    </div>
    <div class="check-circle">✓</div>
  </div>
</body></html>"""


def build_screen_6(lang):
  if lang == "en":
    h1, h2 = "Plant Care", "Schedule"
    plant_h, plant_sub = "Fiddle Leaf Fig", "Ficus lyrata • Living Room"
    tabs = ["Rooms", "Care", "History"]
    plan_t, plan_s = "Personalized Room Care Plan", "Adapted to your light, pot & watering"
    sec_h = "Plant care"
    c1_t, c1_s = "Check Soil Moisture", "Need today"
    c2_t, c2_s = "Follow-Up Photo Check", "Need today"
    c3_t, c3_s = "14-Day Recovery Check", "In 3 days"
  else:
    h1, h2 = "Plan pielęgnacji", "i dziennik"
    plant_h, plant_sub = "Fikus lirolistny", "Ficus lyrata • Salon"
    tabs = ["Pokoje", "Opieka", "Historia"]
    plan_t, plan_s = "Spersonalizowany plan opieki", "Dopasowany do światła i doniczki"
    sec_h = "Zadania pielęgnacji"
    c1_t, c1_s = "Sprawdź wilgotność ziemi", "Na dzisiaj"
    c2_t, c2_s = "Zdjęcie kontrolne liści", "Na dzisiaj"
    c3_t, c3_s = "Kontrola planu 14 dni", "Za 3 dni"

  return f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>{COMMON_CSS}
.hero-card {{
  margin: 44px 44px 32px;
  height: 700px;
  border-radius: 64px;
  overflow: hidden;
  position: relative;
  background: #222B25;
  box-shadow: 0 20px 50px rgba(0,0,0,0.18);
}}
.hero-card img {{
  width: 100%;
  height: 100%;
  object-fit: cover;
}}
.hero-grad {{
  position: absolute;
  left: 0; right: 0; bottom: 0;
  padding: 80px 50px 44px;
  background: linear-gradient(to top, rgba(16, 30, 23, 0.90) 0%, rgba(16, 30, 23, 0.0) 100%);
}}
.hero-title {{
  font-size: 64px;
  font-weight: 900;
  color: #F7F6F0;
  letter-spacing: -0.02em;
}}
.hero-sub {{
  font-size: 42px;
  font-weight: 700;
  color: rgba(247, 246, 240, 0.84);
  margin-top: 8px;
}}

.tabs-pill {{
  margin: 0 44px 32px;
  height: 112px;
  background: #E8EFE5;
  border-radius: 56px;
  display: flex;
  align-items: center;
  padding: 10px;
}}
.tab-p {{
  flex: 1;
  height: 100%;
  border-radius: 48px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 42px;
  font-weight: 800;
  color: #244D3C;
}}
.tab-p.active {{
  background: #244D3C;
  color: #F7F6F0;
  box-shadow: 0 10px 24px rgba(36, 77, 60, 0.30);
}}

.plan-box {{
  margin: 0 44px 34px;
  background: #FFFFFF;
  border: 2px solid #E4E7E0;
  border-radius: 40px;
  padding: 36px 46px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  box-shadow: 0 12px 30px rgba(0,0,0,0.04);
}}
.plan-t {{
  font-size: 46px;
  font-weight: 900;
  color: #202923;
}}
.plan-s {{
  font-size: 38px;
  font-weight: 700;
  color: #53635A;
  margin-top: 8px;
}}
.plan-pct {{
  width: 124px;
  height: 124px;
  border-radius: 50%;
  background: #E8EFE5;
  border: 10px solid #244D3C;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 38px;
  font-weight: 900;
  color: #244D3C;
}}

.sec-header {{
  margin: 0 54px 300px;
  font-size: 52px;
  font-weight: 900;
  color: #202923;
  display: flex;
  align-items: center;
  justify-content: space-between;
}}

.sched-pop {{
  top: 1755px;
  padding: 46px 58px;
  display: flex;
  align-items: center;
  justify-content: space-between;
}}
.sched-t {{
  font-size: 58px;
  font-weight: 900;
  color: #202923;
}}
.sched-s {{
  font-size: 44px;
  font-weight: 800;
  color: #C85A3B;
  margin-top: 10px;
}}
.action-ring {{
  width: 132px;
  height: 132px;
  border-radius: 50%;
  border: 6px solid #C85A3B;
  background: #F9EAE4;
  display: flex;
  align-items: center;
  justify-content: center;
  color: #C85A3B;
  position: relative;
}}
.hand-cursor {{
  position: absolute;
  bottom: -64px;
  right: -48px;
  font-size: 118px;
  filter: drop-shadow(0 14px 24px rgba(0,0,0,0.28));
  transform: rotate(-18deg);
}}

.second-card {{
  margin: 0 44px 28px;
  background: #FFFFFF;
  border: 2px solid #E4E7E0;
  border-radius: 40px;
  padding: 40px 48px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  box-shadow: 0 12px 30px rgba(0,0,0,0.04);
}}
</style></head>
<body>
  <div class="bg-leaf-1"></div>
  <div class="bg-leaf-2"></div>
  <div class="headline-wrap">
    <div class="headline">{h1}<br>{h2}</div>
  </div>

  <div class="phone">
    <div class="phone-screen">
      <div class="notch"></div>
      <div class="hero-card">
        <img src="file://{ASSETS_DIR}/fiddle_clean.png">
        <div class="hero-grad">
          <div class="hero-title">{plant_h}</div>
          <div class="hero-sub">{plant_sub}</div>
        </div>
      </div>

      <div class="tabs-pill">
        <div class="tab-p">{tabs[0]}</div>
        <div class="tab-p active">{tabs[1]}</div>
        <div class="tab-p">{tabs[2]}</div>
      </div>

      <div class="plan-box">
        <div>
          <div class="plan-t">{plan_t}</div>
          <div class="plan-s">{plan_s}</div>
        </div>
        <div class="plan-pct">100%</div>
      </div>

      <div class="sec-header">
        <span>{sec_h}</span>
        <span>{SVG_GEAR}</span>
      </div>

      <div class="second-card">
        <div>
          <div class="plan-t" style="font-size:50px;">{c2_t}</div>
          <div class="sched-s" style="font-size:40px;">{c2_s}</div>
        </div>
        <div class="action-ring" style="width:118px;height:118px;">{SVG_CAMERA}</div>
      </div>

      <div class="second-card">
        <div>
          <div class="plan-t" style="font-size:50px;">{c3_t}</div>
          <div class="plan-s" style="font-size:40px;color:#244D3C;font-weight:800;">{c3_s}</div>
        </div>
        <div class="action-ring" style="width:118px;height:118px;border-color:#244D3C;background:#E8EFE5;color:#244D3C;">✓</div>
      </div>
    </div>
  </div>

  <div class="pop-card sched-pop">
    <div>
      <div class="sched-t">{c1_t}</div>
      <div class="sched-s">{c1_s}</div>
    </div>
    <div class="action-ring">
      {SVG_DROP_ALERT}
      <div class="hand-cursor">👆</div>
    </div>
  </div>
</body></html>"""

SCREENS = [
  ("01_first_help", build_screen_1),
  ("02_recovery_plan", build_screen_2),
  ("03_smart_watering", build_screen_3),
  ("04_photo_id_catalogue", build_screen_4),
  ("05_home_conditions", build_screen_5),
  ("06_collection_diary", build_screen_6),
]

for lang, out_dir in [("en", EN_DIR), ("pl", PL_DIR)]:
  for slug, builder in SCREENS:
    html_path = f"{HTML_DIR}/{slug}_{lang}.html"
    png_path = f"{out_dir}/{slug}_{lang}.png"
    with open(html_path, "w", encoding="utf-8") as f:
      f.write(builder(lang))
    cmd = [
      CHROME_PATH,
      "--headless",
      "--user-data-dir=/tmp/chrome_headless_profile",
      "--disable-gpu",
      "--hide-scrollbars",
      "--force-device-scale-factor=1",
      "--window-size=1320,2868",
      f"--screenshot={png_path}",
      f"file://{html_path}"
    ]
    subprocess.run(cmd, check=True)
    print(f"Rendered {png_path}")

import sys
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    try: b=p.chromium.launch()
    except Exception: b=p.chromium.launch(channel="chrome")
    pg=b.new_page(viewport={"width":1200,"height":900})
    for src,dst in zip(sys.argv[1::2],sys.argv[2::2]):
        pg.goto("file://"+src); pg.screenshot(path=dst, full_page=True)
    b.close()

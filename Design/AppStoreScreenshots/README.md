# App Store screenshots

The finished PNGs are in `iPhone-6.9/` and `iPad-13/`. They use screenshots from the running iOS app with short captions and color backgrounds. The post text, comments, cat photo, and coast photo are synthetic sample content. No Reddit account or live posts are needed to make them. `05-save-media.png` shows the app's media viewer with its real save menu open on a two-image gallery.

The sample content is enabled only in Debug builds launched with `OCTONAUT_SCREENSHOT`. The generated photos are in `content/`, and the simulator captures used by the design script are in `raw/`.

To rebuild the artwork after replacing a capture, run:

```sh
python3 Design/AppStoreScreenshots/render.py
```

The script requires Pillow and macOS Avenir Next. It exports RGB PNGs at 1320 x 2868 for iPhone and 2064 x 2752 for iPad. The iPad artwork uses a portrait capture so the post images remain fully visible.

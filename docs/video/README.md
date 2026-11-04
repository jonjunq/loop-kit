# Video

The 17-second video at the top of the README, made with [HyperFrames](https://github.com/heygen-com/hyperframes)
v0.9.12 (HTML compositions rendered to MP4). No sound.

| File | What it is |
|---|---|
| `loop-kit.mp4`, `loop-kit.es.mp4` | The video (English / Spanish): H.264, 1920×1080, 30 fps, 17 s. Published at [https://jonjunq.github.io/loop-kit/video/loop-kit.mp4](https://jonjunq.github.io/loop-kit/video/loop-kit.mp4) (GitHub Pages serves `docs/`). |
| `poster.jpg`, `poster.es.jpg` | The still the README shows, linked to the video. |

GitHub strips `<video>` tags from READMEs, so the README shows the poster and links to the MP4 on GitHub Pages,
which every browser plays directly.

How the files were made: the 15 s composition is rendered at 34 fps and slowed to 17 s at 30 fps, so every frame
is a distinct rendered frame (no duplicates):

```bash
hyperframes render -q delivery --strict -f 34 -o lk-34fps.mp4
ffmpeg -i lk-34fps.mp4 -vf "setpts=PTS*17/15" -r 30 -c:v libx264 -preset slow -crf 23 \
  -pix_fmt yuv420p -profile:v high -movflags +faststart -an loop-kit.mp4
```

The roadmap and the guard log in the video show sample data; the labels and the guard messages are the kit's own (shortened, and translated in the Spanish version).

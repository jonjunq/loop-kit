# Video

The 17-second animation at the top of the README, made with [HyperFrames](https://github.com/heygen-com/hyperframes)
v0.9.12 (HTML compositions rendered to MP4). No sound.

| File | What it is |
|---|---|
| `loop-kit.webp`, `loop-kit.es.webp` | What the README shows (English / Spanish): animated WebP, 1280×720, 20 fps, 17 s, infinite loop. GitHub draws it inline and it plays by itself. |
| `loop-kit.mp4`, `loop-kit.es.mp4` | The full-quality video the animation links to: H.264, 1920×1080, 30 fps, 17 s. Published at [https://jonjunq.github.io/loop-kit/video/loop-kit.mp4](https://jonjunq.github.io/loop-kit/video/loop-kit.mp4) (GitHub Pages serves `docs/`). |

GitHub strips `<video>` tags from READMEs, so the README uses an animated image. WebP rather than GIF: at the same
size and frame rate a two-pass GIF weighs about 29 MB and dithers the gradients; the WebP is under 5 MB and clean.

How the files were made. The 15 s composition is rendered at the frame rate that, slowed to 17 s, lands exactly on
the target one, so every frame is a distinct rendered frame (no duplicates):

```bash
# MP4: 34 fps × 15 s = 510 frames → 30 fps × 17 s
hyperframes render -q delivery --strict -f 34 -o lk-34fps.mp4
ffmpeg -i lk-34fps.mp4 -vf "setpts=PTS*17/15" -r 30 -c:v libx264 -preset slow -crf 23 \
  -pix_fmt yuv420p -profile:v high -movflags +faststart -an loop-kit.mp4

# WebP: 68/3 fps × 15 s = 340 frames → 20 fps × 17 s
hyperframes render -q delivery --strict -f 68/3 -o lk-20.mp4
ffmpeg -i lk-20.mp4 -vf "setpts=PTS*17/15,fps=20,scale=1280:-2:flags=lanczos" \
  -c:v libwebp_anim -lossless 0 -quality 92 -compression_level 6 -loop 0 -preset picture loop-kit.webp
```

Below quality 92 the dark glows in the background show blocks; above it the file grows past 5 MB.

The roadmap and the guard log in the video show sample data; the labels and the guard messages are the kit's own
(shortened, and translated in the Spanish version).

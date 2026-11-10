# Synthetic mux fixtures

Copied without modification from GopeedLab/gopeed revision a34383a7e226b47207085c953c6f899bc4869637, `pkg/download/engine/testdata/ffmpeg/{video,audio}.mp4`.

The upstream fixtures contain 0.3 seconds of generated 32×32 black H.264 video and generated mono AAC silence, with no third-party media. See that revision's fixture README for the FFmpeg generation commands. The Gopeed GPL-3.0 license is retained in `ios/Resources/Gopeed-LICENSE.txt`.

These files are only bundled into the test target. The proxy server never executes media tooling; iOS AVFoundation mux tests run in GitHub Actions.

# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with versions numbered
`<major>.<minor>` and a two-digit minor (v1.00, v1.01 ... v1.10) to match the release folder names.

## [Unreleased]

## [1.00] - 2026-11-22
First release.

### Added
- **Video details** read with ffprobe: resolution, video format and bit depth, HDR10, HDR10+, HLG and
  Dolby Vision, every sound track, subtitles, size, length and bit rate.
- **TV checks**, red and amber, following what your TV plays (set in Settings...): HEVC, AV1, VP9, 4K,
  HDR, Dolby Vision, DTS (in any file or MKV only), TrueHD and FLAC sound, a sound system on eARC, and a bit-rate limit; plus
  10-bit H.264, bigger than 4K, old XviD/AVI/WMV files, sound the TV can't decode and picture-only
  subtitles.
- **Your TV**: ready-made choices that set the ticks: Sony BRAVIA XR-42A90K (2022) (formats from
  Sony's Help Guide for that TV), and general guides for a typical 4K HDR smart TV, a recent 4K TV with AV1 and
  Dolby Vision, and an older HD TV; or your own choice.
- **File-type checks** while the XR-42A90K is picked: the video, sound, picture size and built-in
  subtitles each file type can hold, from Sony's list for that TV's own player.
- **Export...** as an HTML report (red, amber and green, with search, sorting and Problems only, prints
  cleanly, light or dark) or as a CSV file for Excel.
- Four files read at a time in the background, Stop, and results kept so a later scan only reads new
  or changed files (Scan all again reads everything).
- Totals, Problems only, search, details panel, Play, Open folder, a note with the
  winget command when ffprobe isn't found, light, dark and auto looks, Help and an About box. Listed
  in the Home Launcher's Media tab.

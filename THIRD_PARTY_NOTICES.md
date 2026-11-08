# Third-party licenses and distribution notes

## FFmpeg

Cælōcord launches FFmpeg as a separate executable to create MP4 recordings.
FFmpeg is a separate open-source project; this project does not claim ownership
of its source code or binaries.

- Official website: https://ffmpeg.org/
- Official license and compliance guidance: https://ffmpeg.org/legal.html
- The FFmpeg build fetched by the bundled CI workflow comes from:
  https://www.gyan.dev/ffmpeg/builds/
- The exact version/configuration may activate GPL terms in addition to LGPL.

**Before public redistribution of an FFmpeg-embedded executable:** preserve
FFmpeg's applicable license/copyright notices, make available the corresponding
source code for the exact embedded FFmpeg build and any other applicable GPL
components, and verify other third-party library license requirements. See the
FFmpeg project's official compliance checklist above. The GitHub workflow's
`FFMPEG_BUILD_INFO.txt` records the exact version and SHA-256 of the embedded
binary. Merely linking to FFmpeg's homepage does not necessarily discharge all
source-distribution obligations.

The default small EXE in this starter package does NOT contain FFmpeg. It
invokes the application's existing installation flow only after user consent,
or uses an installed compatible FFmpeg. The GitHub Actions `bundled_ffmpeg`
release contains FFmpeg and requires the additional checks described above.

## Visual artwork

The Moon images are provided by the project owner and are subject to the
project proprietary license (LICENSE.md), where owned by the licensor.
Independently licensed third-party artwork retains its respective terms.

## Windows and PowerShell

Windows, Windows PowerShell, and WPF are Microsoft technologies and are not
redistributed in this repository. The app expects Windows 10/11 with Windows
PowerShell 5.1 available.

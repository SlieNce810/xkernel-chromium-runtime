# CSS 2 GiB screenshot review

- [Warmup at guest 360 s](css-layout-warmup-0360.png): the frame is still blank; this is one of the four startup samples that failed the page profile.
- [First strict pass at guest 481 s](css-layout-pass-0481.png): the official CSS page is visible, including the flex row, 2×2 grid, and box-model geometry.

The remote page gate passed 23 of 27 samples. Four early warmup frames failed; no screenshot after the first pass failed. Raw PPM captures remain on T490; their hashes are in the run-level [manifest](../_ppm-sha256-2026-11-18_t490-codex-2026-11-18_135557-css.txt).
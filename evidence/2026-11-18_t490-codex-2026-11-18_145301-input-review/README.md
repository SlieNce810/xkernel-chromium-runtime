# Input R4 screenshot review

- [Before keyboard echo](r4-before-keyboard-echo.png): the textbox is empty and the Reset control has the visible focus outline.
- [After keyboard echo](r4-after-keyboard-echo.png): the textbox remains at its placeholder; its PPM SHA-256 is identical to the before image.
- [After counter click](r4-after-mouse-click.png): the self-test is green, but the counter still reads 0.
- [After the attempted navigation](r4-after-mouse-navigation.png): the frame still shows `interaction.html`, not the CSS layout page. The corrected `official-layout` strict recheck fails C1, C2, and C3.

The raw PPM screenshots remain on T490. Their hashes are in the adjacent run manifest `../_ppm-sha256-2026-11-18_t490-codex-2026-11-18_145301-input.txt`.
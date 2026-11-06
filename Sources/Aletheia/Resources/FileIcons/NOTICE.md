# File type icons

Static artwork and filename rules imported from https://github.com/file-icons/atom
at fa4bc4850eb5bbc0d192c127fb4be10af3f049b2 (2026-10-24), retrieved 2026-11-06.
The Atom plugin and its JavaScript dependencies are not included or executed.
`upstream.json` records hashes of the imported inputs.

- Catalog / mappings: Daniel Brooker and John Gardner, MIT (Atom.LICENSE).
- file-icons artwork: John Gardner, ISC (FileIcons.LICENSE).
- MFixx: Fizzed, Inc. and John Gardner, MIT (MFixx.LICENSE).
- Devicons / DevOpicons: Theodore Vorillas and contributors; geometry
  optimizations by John Gardner, MIT. See Devicons.LICENSE and both upstream READMEs.
- Font Awesome 4.7.0: Dave Gandy, SIL OFL 1.1 (FontAwesome.LICENSE).
  Original desktop font from
  https://github.com/FortAwesome/Font-Awesome/blob/v4.7.0/fonts/fontawesome-webfont.ttf
- Octicons 4.4.0: GitHub, Inc., MIT (Octicons.LICENSE).
  Atom provides this font itself; imported here from
  https://github.com/primer/octicons/blob/v4.4.0/build/font/octicons.ttf

file-icons, MFixx and DevOpicons WOFF2 resources were losslessly unpacked to
TrueType containers with fontTools 4.60.1 for native CoreText loading. Artwork
was not redesigned. The other two fonts are original upstream desktop files.
Brand icons remain trademarks of their respective owners and imply no endorsement.

The app preserves the ordered file matching rules, including filename and path
rules, and uses the upstream base colors adjusted for light/dark backgrounds.
It fits vector glyph bounds into an 18-point native template image; Atom-specific
CSS offsets, stroke effects and transforms are not used. Git status overrides
icon colors. Directory icons remain the native open/closed folders.

935 icon definitions and 2,088 file rules are included. Ten definitions reference
characters absent from the shipped upstream font: arttext4, bikeshed, dotenv,
figma, imgbot, mint, mixin, photorec, shellcheck and windi. These use native
file-type fallback icons, as do unknown filenames. No file contents, shebangs,
modelines, grammar overrides or .gitattributes are read for icon detection.

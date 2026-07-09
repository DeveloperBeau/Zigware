Stray non-manifest file used by `parse.zig`'s "parseAtBuild silently ignores
unrelated files in the dir" test. The presence of this file must not produce
any diagnostic; the directory scan only recognises basenames of the form
`zigware.<known_os>.zon`.

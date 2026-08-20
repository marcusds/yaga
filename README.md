# Yaga — Yet Another GIF App

A menu bar GIF picker for macOS. Hit **⌥⌘G**, search, then **click to copy** or
**drag straight into** a chat box. Keeps your recent, frequent and favourite
GIFs.

## Build

```sh
./build.sh --install     # build, install to /Applications, launch
./build.sh --dist        # zip for another Mac (Apple silicon, ad-hoc signed)
Yaga --self-test         # exercise the cache
```

Needs the Swift toolchain (Xcode or Command Line Tools).

Ad-hoc signing changes the signature every build, so macOS re-prompts for
Keychain access each time. To stop that, make a self-signed **Code Signing**
certificate named `Yaga Dev` (Keychain Access → Certificate Assistant → Create
a Certificate → Self Signed Root) and `build.sh` will pick it up, or set
`SIGN_IDENTITY` to any identity you have.

## First run

Press **⌘,** and paste a free API key — [GIPHY](https://developers.giphy.com/dashboard/)
or [KLIPY](https://partner.klipy.com/api-keys). Both cap new keys at 100 calls
an hour. Keys live in the Keychain.

## Notes

- Fully keyboard driven. The search box has focus on open; ↓ moves to the shelf
  tabs (←/→ to switch) and on into the grid; arrows move the selection and ↵ or
  Space picks. 1–9 pick the first nine GIFs directly — including as the opening
  keystroke in the empty search box, after which digits type normally. Esc walks
  back up, then closes.
- Pinch or ⌘+/⌘- to change grid density.
- An optional second shortcut (Settings → Behaviour → Insert shortcut, default
  ⌥⌘V) opens the panel in insert mode: your pick is copied, focus returns to the
  app you came from, and ⌘V is pressed for you. The menu bar icon and the main
  shortcut always just copy. Insert mode needs Accessibility access, which macOS
  binds to the app's signature — re-grant it if you rebuild with a different
  identity.
- GIF bytes are content-addressed in `~/Library/Caches/Yaga/`; a daily reaper
  expires unused GIFs after 30 days and trims to 500 MB. Favourites are never
  evicted; GIFs used 3+ times are protected while used in the last 6 months.
- KLIPY's terms forbid retaining their media. That is waived for local
  development — see `GifCache.honourKlipyRetentionTerms` before shipping.
- Copied to another Mac, the app is ad-hoc signed and Gatekeeper will block it
  if the transfer sets a quarantine flag. `rsync`/`scp`/USB do not; AirDrop,
  email and browser downloads do. To clear it:
  `xattr -dr com.apple.quarantine /Applications/Yaga.app`

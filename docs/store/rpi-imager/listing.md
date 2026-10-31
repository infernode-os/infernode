# Raspberry Pi Imager listing

What InferNode's entry in Raspberry Pi Imager is made of, and what to send
Raspberry Pi to have it listed. Imager loads its list of operating systems from
a repository JSON (format V4, Imager 2.0 and later); an operating system that is
not Raspberry Pi's own is added to that list by an application to Raspberry Pi,
who review it ("How to add your own images to Imager",
https://www.raspberrypi.com/news/how-to-add-your-own-images-to-imager/).

## Files

| File | What it is |
|-|-|
| `os_list_infernode.json` | The entry: InferNode, with an item per board. Its sizes and SHA-256s are the published release's |
| `infernode-40.svg` | The icon Imager shows: the InferNode logo, the shipped app icon traced as a vector. Imager takes an SVG or a 40x40 PNG |
| `infernode-40.png` | The same at 40x40, scaled from the 1024 app icon, for anywhere an SVG is not taken |

The logo is unchanged from the app icons (`emu/iOS/.../icon_1024.png`,
`docs/store/google-play/icon-512.png`): orange `#FF6633` on black, as
`TRADEMARK.md` gives it. At 40x40 the symbol is 32 px tall, the policy's minimum.

## The application

- **Name:** InferNode
- **Description:** A 64-bit Inferno® OS that runs on the Pi itself, with no
  Linux underneath: 9P everywhere and namespace-isolated AI agents.
- **Website:** https://www.infernode.io
- **Support:** https://infernode.io/support/ (and
  https://github.com/infernode-os/infernode/issues)
- **Icon:** `infernode-40.svg`, at its raw URL on `master`
- **Images:** the release's `infernode-<version>-rpi3bplus.img.xz` and
  `-rpi4b.img.xz`, signed (sigstore) and with build provenance, from
  https://github.com/infernode-os/infernode/releases
- **Customisation:** none (`init_format: none`). InferNode does not read
  cloud-init or `firstrun.sh`, so Imager's settings screen is off for it. Wi-Fi
  is a `wifi` file on the card (`README.txt` on the card, and
  `docs/BAREMETAL.md` section 5).

## Which boards

Imager's device tags are coarser than what has run InferNode. `pi3-64bit` is
every Pi 3 and the Zero 2 W; `pi4-64bit` is the 4B, the Pi 400 and the CM4.

| Board | Tag | Run on |
|-|-|-|
| Raspberry Pi 3B+ | `pi3-64bit` | yes: boot, HDMI, the first login, Wi-Fi, Bluetooth, Ethernet |
| Raspberry Pi 4B | `pi4-64bit` | yes: boot, HDMI0/HDMI1 and the 7" panel, the first login, Wi-Fi, Bluetooth, Ethernet |
| Pi 3B, 3A+, Zero 2 W | `pi3-64bit` | no. Their radio is not the CYW43455 the card carries firmware for |
| Pi 400, CM4 | `pi4-64bit` | no |

So each item's description names its board, as other images' do ("for RPi
4/400/5 models with 4Gb+").

## Trying the entry before it is listed

Imager reads a repository of your own with `--repo`:

    rpi-imager --repo https://raw.githubusercontent.com/infernode-os/infernode/master/docs/store/rpi-imager/os_list_infernode.json

Choose the board, then InferNode, then the card: it writes and verifies the
image as it would from the official list.

## Each release

The release job prints, for each image, what the entry needs:

    infernode-<v>-rpi3bplus.img: extract_size … extract_sha256 …
    infernode-<v>-rpi3bplus.img.xz: image_download_size … image_download_sha256 …

Put them, the release's URLs and its date into `os_list_infernode.json`, and
check them against the published files before sending them on:

    gh release download v<v> -p 'infernode-<v>-rpi*.img.xz'
    for f in infernode-<v>-rpi*.img.xz; do
      stat -c %s $f; sha256sum $f; xz -dc $f | wc -c; xz -dc $f | sha256sum
    done

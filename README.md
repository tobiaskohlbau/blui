# blUI

**blUI** is an open-source integration layer for **OrcaSlicer**, providing functionality similar to the **BambuLab® plugin**, but without relying on any closed-source or proprietary binaries.

With **blUI**, you can upload, manage, and start prints directly from **OrcaSlicer** — all using transparent, community-auditable code.

---

## ✨ Features

- 🚀 Upload print jobs from OrcaSlicer  
- 🖨️ Start and monitor prints remotely  
- 🔓 Fully open-source — no proprietary dependencies  
- 🧩 Simple setup and clean integration  

---

## 🧰 Installation and usage

### Using pre-built binaries (recommended)

Download the latest nightly build from the [GitHub Releases](https://github.com/tobiaskohlbau/blui/releases) page.

### Verify the signature

All releases are signed with [minisign](https://jedisct1.github.io/minisign/). To verify the signature:

```bash
minisign -Vm blUI-<platform> -P RWS1ZZW+8Lw8jDYlM1i8G7Panirg9TpHUz+Hj77wfk4/Qaxym21lt+wI
```

### Building from source

```bash
git clone https://github.com/tobiaskohlbau/blui.git
cd blui
zig build
./zig-out/bin/blUI --accessCode PRINTER_ACCESS_CODE --ip PRINTER_IP --serial PRINTER_SERIAL
```

### Configuration

blUI required a configuration file. The file is expected to be in ZON format and located at:

- **macOS:** `$XDG_CONFIG_HOME/blui/config.zon`
- **Linux:** `$XDG_CONFIG_HOME/blui/config.zon`
- **Windows:** `%APPDATA%/blui/config.zon`

Command-line arguments override the configuration file values.

Example `config.zon`:

```zon
.{
    .access_code = "your_printer_access_code",
    .ip = "printer_ip_address",
    .serial = "printer_serial_number",
}
```

---

## ⚙️ Compatibility

- **OrcaSlicer:** ✅ Supported  

---

## 🤝 Contributing

Contributions, bug reports, and feature requests are welcome!  
Please open an issue or submit a pull request.

---

## 📜 License

This project is licensed under the [BSD-3 License](LICENSE).

---

> **Disclaimer:**  
> This project is not affiliated with, endorsed by, or associated with **BambuLab®** or **OrcaSlicer**.
All trademarks are the property of their respective owners.

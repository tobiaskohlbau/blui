# blui

**blui** is an open-source integration layer for **OrcaSlicer**, providing functionality similar to the **BambuLab® plugin**, but without relying on any closed-source or proprietary binaries.

With **blui**, you can upload, manage, and start prints directly from **OrcaSlicer** — all using transparent, community-auditable code.

---

## ✨ Features

- 🚀 Upload print jobs from OrcaSlicer  
- 🖨️ Start and monitor prints remotely  
- 🔓 Fully open-source — no proprietary dependencies  
- 🧩 Simple setup and clean integration  

---

## 🧰 Installation and usage

```bash
git clone https://github.com/tobiaskohlbau/blui.git
cd blui
zig build
./zig-out/bin/blui --accessCode PRINTER_ACCESS_CODE --ip PRINTER_IP --serial PRINTER_SERIAL
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

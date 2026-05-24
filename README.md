# 🛸 cachy-ai-tools

A dedicated repository for managing your AI developer tools, token-reduction frameworks, and persistent cross-agent memory layers on Arch Linux and CachyOS. 

This project isolates AI agent developer environments from your core system tweaks, allowing for a lightweight and clean setup.

---

## 🛠️ Included Components

1. **`setup.sh` (Automated Bootstrapper)**
   - Automatically installs NodeJS and NPM using `pacman` if not already present on the system.
   - Installs **`cavemem`** (cross-agent persistent memory SQLite database) globally.
   - Initializes configurations and sets up user-space permissions.

2. **`prompts/` (High-Efficiency Rules)**
   - Includes **`ai-rules.md`**, a custom system prompt template designed to strip out conversational pleasantries, adverbs, and filler words, reducing output tokens by approximately 70% while keeping technical substance intact.

---

## 🚀 Getting Started

To initialize the AI tools stack on your local machine, run the setup script:

```bash
chmod +x setup.sh
sudo ./setup.sh
```

---

## ⚡ Usage Reference

### 1. Cross-Session Persistent Memory (`cavemem`)
- **Check active database status:**
  ```bash
  cavemem status
  ```
- **Launch the Local Web Viewer:**
  Run the viewer to browse and query all stored coding agent observations and sessions in a clean dashboard:
  ```bash
  cavemem viewer
  ```
  Open your web browser at: [http://127.0.0.1:37777](http://127.0.0.1:37777)

### 2. Output Token Compressor (`caveman`)
- **For Claude Code or compatible agents:**
  Load the skill directly in your workspace:
  ```bash
  npx skills add JuliusBrussee/caveman
  ```
- Use the rules defined in `prompts/ai-rules.md` inside your agent's system configurations to ensure highly terse and efficient outputs.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

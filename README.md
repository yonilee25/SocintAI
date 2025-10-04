# SocintAI 
## Prerequisites
- **Node.js ≥ 18.17 (LTS)** – Next.js 14 drops support for Node 16 and requires at least Node 18.17
nextjs.org. Node 20 LTS or higher is fine.
- **pnpm** – The pnpm package manager needs Node ≥ 18.12
pnpm.io. It is used by the frontend to install dependencies and run development scripts.
- **Rust and Cargo** – Install the Rust toolchain via rustup. The official installation page recommends downloading rustup‑init.exe on Windows or running the curl installer on Unix-like systems
- **cargo‑watch** – A small tool that watches source files and runs a cargo command. Install it with cargo install cargo-watch
docs.rs.
- **just** – A command runner used for the justfile. Install via your package manager (e.g., brew install just) or using Cargo with cargo install just

## 1. Installing the dependencies
Below are common installation methods for each prerequisite. Adjust paths and commands according to your operating system.
### Node.js and pnpm
1. **Install Node.js (LTS)** - On Windows, use the official MSI installer or the nvm‑windows
 binary. After installation, restart your terminal and verify with **node -v**.
2. **Install pnpm** 
* With Node.js installed, you can globally install pnpm via npm:
```
npm install -g pnpm@latest
```
### Rust toolchain and cargo‑watch
1. **Install Rust via rustup**
On Windows, download and run **rustup-init.exe** from the official installer and follow the prompts. You may need to install the Visual Studio C++ build tools when prompted.
* This installs rustc, cargo and rustup. Restart your terminal and verify by running rustc --version.
2. **Install cargo‑watch**
- Use Cargo to install the cargo-watch crate globally:
```
cargo install cargo-watch
````
- The **cargo watch** command will monitor your Rust sources and automatically run cargo run whenever changes are detected.
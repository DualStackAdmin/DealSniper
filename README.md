# 🎯 DealSniper - Automated Marketplace Monitor

DealSniper is a powerful, self-hosted web application designed to monitor the **Tap.az** marketplace for specific products. It automatically scrapes listing data, filters by price/date, and sends instant notifications to **Telegram**.

![DealSniper Dashboard](DealSniper.jpg)

## 🚀 Features

* **🕵️‍♂️ Intelligent Scraping:** Monitors listings in the background without blocking the UI.
* **📱 Telegram Alerts:** Receive instant notifications with product details and links.
* **💻 Web Dashboard:** Clean, responsive Bootstrap interface to manage tasks.
* **⚙️ Advanced Filters:** Filter by Keyword, Price Range (Min/Max), and Date (Today/Yesterday).
* **🛡️ Anti-Detection:** Optimized headers and request delays to prevent IP blocking.
* **🔧 Self-Hosted:** Runs as a Systemd service on Linux (Ubuntu/Debian).

---

## 🤖 How to get Telegram Credentials (Required)

Before installing, you need to get your **Bot Token** and **Chat ID**. It takes 1 minute:

### 1. Get Bot Token
1. Open Telegram and search for **[@BotFather](https://t.me/BotFather)**.
2. Send the command `/newbot`.
3. Give your bot a name (e.g., `MySniperBot`) and a username (must end in `bot`, e.g., `MySniper_bot`).
4. Copy the **HTTP API Token** (It looks like: `123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11`).

### 2. Get Chat ID
1. Search for **[@userinfobot](https://t.me/userinfobot)** on Telegram.
2. Click **Start**.
3. Copy the number next to **Id** (e.g., `12345678`).

### ⚠️ IMPORTANT STEP
**You must find your new bot (search its username) and click START. If you don't do this, the bot cannot send you messages!**

---

## 🛠️ Installation

You can install DealSniper with a single command on your VPS.

1. Connect to your server (Ubuntu/Debian).
2. Run the following command block:

```bash
wget -O install.sh https://raw.githubusercontent.com/DualStackAdmin/DealSniper/main/install.sh && sed -i 's/\r$//' install.sh && sudo bash install.sh


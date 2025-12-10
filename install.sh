#!/bin/bash

# --- COLORS ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}🚀 Installing DealSniper v5 (Interactive & Stable)...${NC}"

# --- 1. PROMPT FOR TOKEN AND ID ---
echo ""
echo -e "${CYAN}=== Telegram Configuration ===${NC}"
read -p "Enter Bot Token: " USER_TOKEN
read -p "Enter Chat ID: " USER_CHAT_ID

if [[ -z "$USER_TOKEN" || -z "$USER_CHAT_ID" ]]; then
    echo -e "${RED}Error: Token and Chat ID cannot be empty!${NC}"
    exit 1
fi

# --- 2. CLEANUP ---
echo -e "${CYAN}🧹 Cleaning up old files...${NC}"
systemctl stop dealsniper 2>/dev/null
systemctl disable dealsniper 2>/dev/null
# Kill anything stuck on port 5000
fuser -k 5000/tcp > /dev/null 2>&1
rm -rf /opt/dealsniper

# --- 3. INSTALLATION ---
echo -e "${CYAN}📦 Installing dependencies...${NC}"
apt-get update -y > /dev/null 2>&1
apt-get install -y python3 python3-venv python3-pip python3-full sqlite3 wget psmisc > /dev/null 2>&1

APP_DIR="/opt/dealsniper"
mkdir -p $APP_DIR/templates
mkdir -p $APP_DIR/static
cd $APP_DIR

# --- 4. DESIGN (LOCAL) ---
echo -e "${CYAN}🎨 Downloading local design assets...${NC}"
wget -q https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css -O $APP_DIR/static/bootstrap.min.css
wget -q https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js -O $APP_DIR/static/bootstrap.bundle.min.js

# --- 5. PYTHON ENVIRONMENT ---
python3 -m venv venv
$APP_DIR/venv/bin/pip install flask requests beautifulsoup4 flask-login werkzeug > /dev/null 2>&1

# --- 6. WRITE CONFIG ---
# Saving user input directly to config file
echo "{\"token\": \"$USER_TOKEN\", \"chat_id\": \"$USER_CHAT_ID\"}" > config.json
chmod 777 config.json

# --- 7. APP CODE (FIXED SYNTAX) ---
cat > $APP_DIR/app.py <<EOL
import requests
from bs4 import BeautifulSoup
from flask import Flask, render_template, request, redirect, url_for, flash
from flask_login import LoginManager, UserMixin, login_user, login_required, logout_user, current_user
from werkzeug.security import generate_password_hash, check_password_hash
import threading
import time
import json
import os
import sqlite3
from datetime import datetime

app = Flask(__name__)
app.secret_key = 'dealsniper_v5_secret'

DB_FILE = 'dealsniper.db'
CONFIG_FILE = 'config.json'

def init_db():
    conn = sqlite3.connect(DB_FILE)
    c = conn.cursor()
    c.execute('''CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE, password TEXT, chat_id TEXT)''')
    c.execute('''CREATE TABLE IF NOT EXISTS tasks (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER, keyword TEXT, date_filter TEXT, min_price INTEGER, max_price INTEGER, status TEXT, last_check TEXT, found_count INTEGER)''')
    c.execute('''CREATE TABLE IF NOT EXISTS results (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id INTEGER, title TEXT, price INTEGER, link TEXT, found_time TEXT)''')
    conn.commit()
    conn.close()

init_db()

def load_config():
    if not os.path.exists(CONFIG_FILE):
        return {"token": "", "chat_id": ""}
    try:
        with open(CONFIG_FILE, 'r') as f:
            return json.load(f)
    except:
        return {"token": "", "chat_id": ""}

def save_config(token, chat_id):
    with open(CONFIG_FILE, 'w') as f:
        json.dump({"token": token.strip(), "chat_id": chat_id.strip()}, f)

login_manager = LoginManager()
login_manager.init_app(app)
login_manager.login_view = 'login'

class User(UserMixin):
    def __init__(self, id, username, chat_id):
        self.id = id
        self.username = username
        self.chat_id = chat_id

@login_manager.user_loader
def load_user(user_id):
    conn = sqlite3.connect(DB_FILE)
    c = conn.cursor()
    c.execute("SELECT id, username, chat_id FROM users WHERE id = ?", (user_id,))
    user_data = c.fetchone()
    conn.close()
    if user_data: return User(user_data[0], user_data[1], user_data[2])
    return None

def send_telegram(chat_id, message):
    config = load_config()
    token = config.get('token')
    if not token or not chat_id: return
    try:
        url = f"https://api.telegram.org/bot{token}/sendMessage"
        requests.post(url, data={"chat_id": chat_id, "text": message, "parse_mode": "HTML", "disable_web_page_preview": True})
    except: pass

processed_urls = set()

def scraper_thread():
    while True:
        try:
            conn = sqlite3.connect(DB_FILE)
            c = conn.cursor()
            c.execute('''SELECT t.id, t.keyword, t.min_price, t.max_price, t.date_filter, u.chat_id, t.status 
                         FROM tasks t JOIN users u ON t.user_id = u.id WHERE t.status = "running"''')
            active_tasks = c.fetchall()
            conn.close()

            if not active_tasks:
                time.sleep(3)
                continue

            for task in active_tasks:
                t_id, keyword, min_p, max_p, date_filter, chat_id, status = task
                
                try:
                    conn = sqlite3.connect(DB_FILE)
                    conn.execute("UPDATE tasks SET last_check = ? WHERE id = ?", (datetime.now().strftime('%H:%M:%S'), t_id))
                    conn.commit()
                    conn.close()
                except: pass

                url = f"https://tap.az/elanlar?keywords={keyword}"
                headers = {'User-Agent': 'Mozilla/5.0'}
                
                try:
                    resp = requests.get(url, headers=headers, timeout=10)
                    if resp.status_code == 200:
                        soup = BeautifulSoup(resp.text, 'html.parser')
                        items = soup.select('div.products-i')
                        
                        for item in items:
                            try:
                                conn = sqlite3.connect(DB_FILE)
                                check = conn.execute("SELECT status FROM tasks WHERE id=?", (t_id,)).fetchone()
                                conn.close()
                                if not check or check[0] != 'running': break

                                link_tag = item.select_one('a.products-link')
                                if not link_tag: continue
                                href = "https://tap.az" + link_tag['href']
                                
                                title = item.select_one('div.products-name').text.strip()
                                price_tag = item.select_one('span.price-val')
                                price_text = price_tag.text.replace(' ', '').replace('AZN', '') if price_tag else "0"
                                price = int(''.join(filter(str.isdigit, price_text)) or 0)
                                date_text = item.select_one('div.products-created').text.strip().lower()

                                if href in processed_urls: continue
                                
                                conn = sqlite3.connect(DB_FILE)
                                exists = conn.execute("SELECT id FROM results WHERE link = ? AND task_id = ?", (href, t_id)).fetchone()
                                conn.close()
                                if exists:
                                    processed_urls.add(href)
                                    continue
                                
                                p_min = int(min_p or 0)
                                p_max = int(max_p or 9999999)
                                if price < p_min or price > p_max: continue
                                
                                if date_filter == 'today' and 'bugün' not in date_text: continue
                                elif date_filter == 'today_yesterday' and 'bugün' not in date_text and 'dünən' not in date_text: continue
                                
                                processed_urls.add(href)
                                
                                conn = sqlite3.connect(DB_FILE)
                                conn.execute("INSERT INTO results (task_id, title, price, link, found_time) VALUES (?, ?, ?, ?, ?)",
                                             (t_id, title, price, href, datetime.now().strftime('%H:%M')))
                                conn.execute("UPDATE tasks SET found_count = found_count + 1 WHERE id = ?", (t_id,))
                                conn.commit()
                                conn.close()
                                
                                msg = f"🔥 <b>Found!</b>\n🔍 {keyword}\n🏷️ {title}\n💰 <b>{price} AZN</b>\n🔗 <a href='{href}'>Link</a>"
                                send_telegram(chat_id, msg)
                                time.sleep(1)
                            except: continue
                except: pass
                time.sleep(1)
        except: pass
        time.sleep(2)

t = threading.Thread(target=scraper_thread)
t.daemon = True
t.start()

# --- FLASK ROUTES ---
@app.route('/')
@login_required
def index():
    conn = sqlite3.connect(DB_FILE)
    c = conn.cursor()
    c.execute("SELECT * FROM tasks WHERE user_id = ?", (current_user.id,))
    my_tasks = c.fetchall()
    c.execute('''SELECT r.title, r.price, r.link, r.found_time, t.keyword
                 FROM results r JOIN tasks t ON r.task_id = t.id 
                 WHERE t.user_id = ? ORDER BY r.id DESC LIMIT 50''', (current_user.id,))
    my_results = c.fetchall()
    conn.close()
    return render_template('index.html', tasks=my_tasks, results=my_results, user=current_user, config=load_config())

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form['username']
        password = request.form['password']
        conn = sqlite3.connect(DB_FILE)
        c = conn.cursor()
        c.execute("SELECT id, username, password, chat_id FROM users WHERE username = ?", (username,))
        user = c.fetchone()
        conn.close()
        if user and check_password_hash(user[2], password):
            login_user(User(user[0], user[1], user[3]))
            return redirect('/')
        else: flash('Error! Invalid credentials.')
    return render_template('login.html')

@app.route('/register', methods=['GET', 'POST'])
def register():
    if request.method == 'POST':
        username = request.form['username']
        password = request.form['password']
        chat_id = request.form['chat_id']
        hashed_pw = generate_password_hash(password)
        try:
            conn = sqlite3.connect(DB_FILE)
            conn.execute("INSERT INTO users (username, password, chat_id) VALUES (?, ?, ?)", (username, hashed_pw, chat_id))
            conn.commit()
            conn.close()
            return redirect('/login')
        except: flash('Username taken')
    return render_template('register.html')

@app.route('/logout')
@login_required
def logout():
    logout_user()
    return redirect('/login')

@app.route('/add', methods=['POST'])
@login_required
def add_task():
    keyword = request.form['keyword']
    date = request.form['date_filter']
    min_p = request.form['min_price']
    max_p = request.form['max_price']
    conn = sqlite3.connect(DB_FILE)
    conn.execute('''INSERT INTO tasks (user_id, keyword, date_filter, min_price, max_price, status, last_check, found_count) VALUES (?, ?, ?, ?, ?, 'running', '...', 0)''', (current_user.id, keyword, date, min_p, max_p))
    conn.commit()
    conn.close()
    return redirect('/')

@app.route('/action/<action>/<int:task_id>')
@login_required
def task_action(action, task_id):
    conn = sqlite3.connect(DB_FILE)
    if action == 'stop': conn.execute("UPDATE tasks SET status = 'stopped' WHERE id = ? AND user_id = ?", (task_id, current_user.id))
    elif action == 'start': conn.execute("UPDATE tasks SET status = 'running' WHERE id = ? AND user_id = ?", (task_id, current_user.id))
    elif action == 'delete':
        conn.execute("DELETE FROM tasks WHERE id = ? AND user_id = ?", (task_id, current_user.id))
        conn.execute("DELETE FROM results WHERE task_id = ?", (task_id,))
    conn.commit()
    conn.close()
    return redirect('/')

@app.route('/update_settings', methods=['POST'])
@login_required
def update_settings():
    new_chat_id = request.form.get('chat_id')
    new_token = request.form.get('token')
    if new_chat_id:
        conn = sqlite3.connect(DB_FILE)
        conn.execute("UPDATE users SET chat_id = ? WHERE id = ?", (new_chat_id, current_user.id))
        conn.commit()
        conn.close()
    current_conf = load_config()
    save_config(new_token if new_token else current_conf.get('token', ''), current_conf.get('chat_id', ''))
    return redirect('/')

@app.route('/clear_results')
@login_required
def clear_results():
    conn = sqlite3.connect(DB_FILE)
    conn.execute("DELETE FROM results WHERE task_id IN (SELECT id FROM tasks WHERE user_id = ?)", (current_user.id,))
    conn.commit()
    conn.close()
    return redirect('/')

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOL

# --- 8. CLEAN LIGHT CSS (Correct Colors) ---
CUSTOM_CSS="
<style>
    body { background-color: #f8f9fa; color: #212529; font-family: 'Segoe UI', sans-serif; }
    .card { background-color: #ffffff; border: 1px solid #dee2e6; box-shadow: 0 0.125rem 0.25rem rgba(0, 0, 0, 0.075); border-radius: 0.5rem; }
    .form-control, .form-select { background-color: #ffffff; border: 1px solid #ced4da; color: #212529; }
    .form-control:focus { border-color: #86b7fe; box-shadow: 0 0 0 0.25rem rgba(13, 110, 253, 0.25); }
    .task-card { border-left: 5px solid #6c757d; transition: transform 0.2s; }
    .task-card:hover { transform: translateY(-3px); }
    .running { border-left-color: #198754; background-color: #f1fef6; }
    .stopped { border-left-color: #dc3545; background-color: #fef1f2; opacity: 0.8; }
    .list-group-item { background-color: #ffffff; color: #212529; border: 1px solid #dee2e6; margin-bottom: 5px; border-radius: 5px !important; }
    .list-group-item:hover { background-color: #f8f9fa; }
    a { text-decoration: none; }
    .badge-price { background-color: #198754; color: white; padding: 5px 10px; border-radius: 10px; font-weight: bold; }
    .text-primary { color: #0d6efd !important; }
    .navbar { background-color: #ffffff !important; border-bottom: 1px solid #dee2e6; }
</style>
"

# --- 9. HTML PAGES ---

cat > $APP_DIR/templates/login.html <<EOL
<!DOCTYPE html>
<html>
<head>
    <title>Login</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link href="/static/bootstrap.min.css" rel="stylesheet">
    $CUSTOM_CSS
</head>
<body class="d-flex align-items-center justify-content-center" style="height: 100vh;">
    <div class="card p-5" style="width: 400px;">
        <h3 class="text-center mb-4 fw-bold text-primary">DealSniper v5</h3>
        {% with messages = get_flashed_messages() %}
            {% if messages %}<div class="alert alert-danger py-2">{{ messages[0] }}</div>{% endif %}
        {% endwith %}
        <form method="POST">
            <div class="mb-3">
                <label class="form-label fw-bold">Username</label>
                <input type="text" name="username" class="form-control" required>
            </div>
            <div class="mb-4">
                <label class="form-label fw-bold">Password</label>
                <input type="password" name="password" class="form-control" required>
            </div>
            <button class="btn btn-primary w-100 py-2 fw-bold">Login</button>
        </form>
        <div class="text-center mt-3"><a href="/register">Create New Account</a></div>
    </div>
</body>
</html>
EOL

cat > $APP_DIR/templates/register.html <<EOL
<!DOCTYPE html>
<html>
<head>
    <title>Register</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link href="/static/bootstrap.min.css" rel="stylesheet">
    $CUSTOM_CSS
</head>
<body class="d-flex align-items-center justify-content-center" style="height: 100vh;">
    <div class="card p-5" style="width: 400px;">
        <h3 class="text-center mb-4 fw-bold text-success">Register</h3>
        {% with messages = get_flashed_messages() %}
            {% if messages %}<div class="alert alert-danger py-2">{{ messages[0] }}</div>{% endif %}
        {% endwith %}
        <form method="POST">
            <div class="mb-3">
                <label class="form-label fw-bold">Username</label>
                <input type="text" name="username" class="form-control" required>
            </div>
            <div class="mb-3">
                <label class="form-label fw-bold">Password</label>
                <input type="password" name="password" class="form-control" required>
            </div>
            <div class="mb-4">
                <label class="form-label fw-bold">Telegram Chat ID</label>
                <input type="text" name="chat_id" class="form-control" placeholder="12345678" required>
            </div>
            <button class="btn btn-success w-100 py-2 fw-bold">Sign Up</button>
        </form>
        <div class="text-center mt-3"><a href="/login">Back to Login</a></div>
    </div>
</body>
</html>
EOL

cat > $APP_DIR/templates/index.html <<EOL
<!DOCTYPE html>
<html>
<head>
    <title>Panel</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link href="/static/bootstrap.min.css" rel="stylesheet">
    <meta http-equiv="refresh" content="30">
    $CUSTOM_CSS
</head>
<body class="p-4">
    <div class="container" style="max-width: 1000px;">
        <div class="card p-3 mb-4 d-flex flex-row justify-content-between align-items-center">
            <h4 class="m-0 fw-bold text-primary">DealSniper <span class="badge bg-secondary fs-6">v5</span></h4>
            <div class="d-flex align-items-center gap-3">
                <span class="fw-bold text-dark">{{ user.username }}</span>
                <button class="btn btn-outline-secondary btn-sm" data-bs-toggle="modal" data-bs-target="#settingsModal">Settings</button>
                <a href="/logout" class="btn btn-danger btn-sm">Logout</a>
            </div>
        </div>

        <div class="modal fade" id="settingsModal" tabindex="-1">
            <div class="modal-dialog">
                <div class="modal-content">
                    <div class="modal-header"><h5 class="modal-title">Account Settings</h5><button type="button" class="btn-close" data-bs-dismiss="modal"></button></div>
                    <form action="/update_settings" method="POST">
                        <div class="modal-body">
                            <label class="form-label">Telegram Chat ID</label>
                            <input type="text" name="chat_id" class="form-control mb-3" value="{{ user.chat_id }}" required>
                            <label class="form-label">Bot Token</label>
                            <input type="text" name="token" class="form-control" value="{{ config.token }}">
                        </div>
                        <div class="modal-footer"><button class="btn btn-primary">Save Changes</button></div>
                    </form>
                </div>
            </div>
        </div>

        <div class="card p-4 mb-4">
            <h5 class="mb-3 fw-bold text-secondary">New Search</h5>
            <form action="/add" method="POST">
                <div class="row g-3">
                    <div class="col-md-4">
                        <label class="form-label small text-muted">Keyword</label>
                        <input type="text" name="keyword" class="form-control" placeholder="e.g. iPhone 13" required>
                    </div>
                    <div class="col-md-3">
                        <label class="form-label small text-muted">Date</label>
                        <select name="date_filter" class="form-select">
                            <option value="all">All Dates</option>
                            <option value="today">Today Only</option>
                            <option value="today_yesterday">Today + Yesterday</option>
                        </select>
                    </div>
                    <div class="col-md-2">
                        <label class="form-label small text-muted">Min AZN</label>
                        <input type="number" name="min_price" class="form-control" placeholder="0">
                    </div>
                    <div class="col-md-2">
                        <label class="form-label small text-muted">Max AZN</label>
                        <input type="number" name="max_price" class="form-control" placeholder="Max">
                    </div>
                    <div class="col-md-1 d-flex align-items-end">
                        <button class="btn btn-success w-100 fw-bold">Start</button>
                    </div>
                </div>
            </form>
        </div>

        <h6 class="text-uppercase text-muted fw-bold mb-3">Active Tasks ({{ tasks|length }})</h6>
        <div class="row mb-4">
            {% for task in tasks %}
            <div class="col-md-6">
                <div class="card p-3 mb-3 task-card {% if task[6] == 'running' %}running{% else %}stopped{% endif %}">
                    <div class="d-flex justify-content-between align-items-center">
                        <div>
                            <h5 class="m-0 fw-bold">{{ task[2] }}</h5>
                            <small class="text-muted">Last check: {{ task[7] }} | Found: <b>{{ task[8] }}</b></small>
                        </div>
                        <div class="btn-group">
                            {% if task[6] == 'running' %}
                                <a href="/action/stop/{{ task[0] }}" class="btn btn-sm btn-warning">Stop</a>
                            {% else %}
                                <a href="/action/start/{{ task[0] }}" class="btn btn-sm btn-success">Start</a>
                            {% endif %}
                            <a href="/action/delete/{{ task[0] }}" class="btn btn-sm btn-danger">Delete</a>
                        </div>
                    </div>
                </div>
            </div>
            {% else %}
                <div class="col-12"><div class="alert alert-secondary text-center">No searches yet.</div></div>
            {% endfor %}
        </div>

        <div class="d-flex justify-content-between align-items-center mb-3">
            <h5 class="m-0 fw-bold">Latest Results</h5>
            <a href="/clear_results" class="btn btn-sm btn-outline-danger">Clear</a>
        </div>
        <div class="list-group shadow-sm">
            {% for res in results %}
            <a href="{{ res[2] }}" target="_blank" class="list-group-item list-group-item-action p-3">
                <div class="d-flex justify-content-between align-items-center">
                    <div>
                        <h6 class="mb-1 fw-bold text-primary">{{ res[0] }}</h6>
                        <small class="text-muted">{{ res[4] }} | {{ res[3] }}</small>
                    </div>
                    <span class="badge-price">{{ res[1] }} AZN</span>
                </div>
            </a>
            {% else %}
                <div class="p-4 text-center text-muted border rounded bg-white">No results found yet.</div>
            {% endfor %}
        </div>
    </div>
    <script src="/static/bootstrap.bundle.min.js"></script>
</body>
</html>
EOL

# --- 10. SYSTEMD ---
cat > /etc/systemd/system/dealsniper.service <<EOL
[Unit]
Description=DealSniper v5 Final
After=network.target

[Service]
User=root
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/python3 app.py
Restart=always
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOL

systemctl daemon-reload
systemctl enable dealsniper > /dev/null 2>&1
systemctl restart dealsniper

# --- 11. CHECK STATUS ---
echo -e "${CYAN}🔍 Checking service status...${NC}"
sleep 2
if systemctl is-active --quiet dealsniper; then
    IP=$(hostname -I | cut -d' ' -f1)
    echo -e "\n${GREEN}✅ Installation Successful!${NC}"
    echo -e "🔗 Link: http://$IP:5000"
    echo -e "💡 Note: You can now create a new account and log in."
else
    echo -e "\n${RED}❌ Error occurred! To view logs:${NC}"
    echo "journalctl -u dealsniper -n 20 --no-pager"
fi

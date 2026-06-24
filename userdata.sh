#!/bin/bash
set -euo pipefail
exec > /var/log/userdata.log 2>&1

# ── system ────────────────────────────────────────────────────────────────────
dnf update -y -q
dnf install -y -q nginx python3 python3-pip

# ── app user & directory ───────────────────────────────────────────────────────
useradd -r -s /sbin/nologin appuser
mkdir -p /var/app
chown appuser:appuser /var/app

# ── flask app ─────────────────────────────────────────────────────────────────
pip3 install -q flask==3.0.3

cat > /var/app/app.py << 'PYEOF'
import sqlite3, os
from flask import Flask, request, redirect, url_for, g

app = Flask(__name__)
DB = os.environ.get("DB_PATH", "/var/app/tasks.db")

def get_db():
    if "db" not in g:
        g.db = sqlite3.connect(DB, detect_types=sqlite3.PARSE_DECLTYPES)
        g.db.row_factory = sqlite3.Row
    return g.db

@app.teardown_appcontext
def close_db(e=None):
    db = g.pop("db", None)
    if db:
        db.close()

def init_db():
    with app.app_context():
        db = get_db()
        db.execute("""
            CREATE TABLE IF NOT EXISTS tasks (
                id   INTEGER PRIMARY KEY AUTOINCREMENT,
                text TEXT    NOT NULL,
                done INTEGER NOT NULL DEFAULT 0
            )
        """)
        db.commit()

@app.route("/")
def index():
    tasks = get_db().execute("SELECT * FROM tasks ORDER BY id DESC").fetchall()
    rows = ""
    for t in tasks:
        check = "&#10003;" if t["done"] else "&middot;"
        text  = ("<s>" + t["text"] + "</s>") if t["done"] else t["text"]
        tid   = str(t["id"])
        done_btn = ("" if t["done"] else
            '<form method="post" action="/task/' + tid + '/done" style="display:inline">'
            '<button>done</button></form>')
        del_btn = (
            '<form method="post" action="/task/' + tid + '/delete" style="display:inline">'
            '<button>del</button></form>')
        rows += "<tr><td>" + check + "</td><td>" + text + "</td><td>" + done_btn + del_btn + "</td></tr>"
    return f"""<!doctype html>
<html><head><title>Task List</title>
<style>body{{font-family:monospace;max-width:600px;margin:40px auto;padding:0 20px}}
table{{width:100%}}td{{padding:4px 8px}}button{{cursor:pointer}}</style>
</head><body>
<h2>Task List</h2>
<form method="post" action="/task">
  <input name="text" placeholder="new task..." style="width:70%" required>
  <button type="submit">add</button>
</form>
<br>
<table><tbody>{rows}</tbody></table>
<p style="color:#888;font-size:12px">host: {os.uname().nodename}</p>
</body></html>"""

@app.route("/task", methods=["POST"])
def add_task():
    text = request.form["text"].strip()
    if text:
        db = get_db()
        db.execute("INSERT INTO tasks (text) VALUES (?)", (text,))
        db.commit()
    return redirect(url_for("index"))

@app.route("/task/<int:task_id>/done", methods=["POST"])
def mark_done(task_id):
    db = get_db()
    db.execute("UPDATE tasks SET done=1 WHERE id=?", (task_id,))
    db.commit()
    return redirect(url_for("index"))

@app.route("/task/<int:task_id>/delete", methods=["POST"])
def delete_task(task_id):
    db = get_db()
    db.execute("DELETE FROM tasks WHERE id=?", (task_id,))
    db.commit()
    return redirect(url_for("index"))

@app.route("/health")
def health():
    return "ok"

if __name__ == "__main__":
    init_db()
    app.run(host="127.0.0.1", port=5000)
PYEOF

chown appuser:appuser /var/app/app.py

# init db as appuser
sudo -u appuser python3 -c "
import sqlite3
db = sqlite3.connect('/var/app/tasks.db')
db.execute('CREATE TABLE IF NOT EXISTS tasks (id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0)')
db.execute(\"INSERT INTO tasks (text) VALUES ('Deploy the app')\")
db.execute(\"INSERT INTO tasks (text) VALUES ('Check the logs')\")
db.execute(\"INSERT INTO tasks (text) VALUES ('Fix the bug')\")
db.commit()
db.close()
"

# ── systemd service ────────────────────────────────────────────────────────────
cat > /etc/systemd/system/taskapp.service << 'SVCEOF'
[Unit]
Description=Task List Flask App
After=network.target

[Service]
User=appuser
WorkingDirectory=/var/app
Environment="DB_PATH=/var/app/tasks.db"
ExecStart=/usr/bin/python3 /var/app/app.py
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable taskapp
systemctl start taskapp

# ── nginx ─────────────────────────────────────────────────────────────────────
cat > /etc/nginx/conf.d/taskapp.conf << 'NGEOF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass         http://127.0.0.1:5000;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_read_timeout 30s;
    }

    location /health {
        proxy_pass http://127.0.0.1:5000/health;
        access_log off;
    }
}
NGEOF

# remove default nginx site and strip the built-in server{} block from nginx.conf
# (AL2023 nginx.conf has a server{} directly in http{} that conflicts with conf.d/)
rm -f /etc/nginx/conf.d/default.conf
python3 - << 'PYEOF'
import re, pathlib
p = pathlib.Path("/etc/nginx/nginx.conf")
txt = p.read_text()
# remove the server { ... } block that nginx ships with
txt = re.sub(r'\n\s*server\s*\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}', '', txt, count=1)
p.write_text(txt)
PYEOF

nginx -t
systemctl enable nginx
systemctl start nginx

echo "=== userdata done ==="

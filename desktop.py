# -*- coding: utf-8 -*-
"""Native Windows window wrapper for the local OT Laundry web application."""
from threading import Thread
import time

import webview
from waitress import serve

from app import app


def run_local_server():
    serve(app, host="127.0.0.1", port=8765, threads=8)


if __name__ == "__main__":
    server = Thread(target=run_local_server, daemon=True, name="ot-laundry-server")
    server.start()
    time.sleep(0.8)
    webview.create_window(
        "OT Laundry",
        "http://127.0.0.1:8765",
        width=1360,
        height=860,
        min_size=(1024, 700),
        background_color="#f6f6f8",
    )
    webview.start(debug=False)

"""ASGI entry point. uvicorn (dev) or gunicorn+uvicorn-workers (prod) load
`application` for HTTP + websocket."""
import os
from pathlib import Path

try:
    from dotenv import load_dotenv

    _root = Path(__file__).resolve().parent.parent
    load_dotenv(_root / ".env")
    load_dotenv(_root / ".env.local", override=True)
except ImportError:
    pass

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings.dev")

from django.core.asgi import get_asgi_application  # noqa: E402

application = get_asgi_application()

import pytest


@pytest.fixture
def app_env(tmp_path):
    import config
    import db as db_mod
    config.BASE_DIR = tmp_path
    config.EVENTS_DIR = tmp_path / "events"
    config.EVENTS_DIR.mkdir()
    db_mod.MAIN_DB_PATH = tmp_path / "main.sqlite"
    return tmp_path


@pytest.fixture
def _app(app_env):
    import config
    _orig = config.SESSION_COOKIE_DOMAIN
    config.SESSION_COOKIE_DOMAIN = None
    from app import create_app
    app = create_app()
    config.SESSION_COOKIE_DOMAIN = _orig
    app.config["TESTING"] = True
    app.config["SESSION_COOKIE_DOMAIN"] = None
    return app


@pytest.fixture
def client(_app):
    with _app.test_client() as c:
        with c.session_transaction() as sess:
            sess["username"] = "admin"
        yield c


@pytest.fixture
def anon_client(_app):
    with _app.test_client() as c:
        yield c

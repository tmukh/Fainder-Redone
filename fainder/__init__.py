__version__ = "0.1.0"

# Re-export from the Rust extension (installed as fainder.fainder_core)
try:
    from .fainder_core import RebinningIndex  # noqa: F401
except Exception:
    # Allow importing fainder even if the extension isn't built yet
    pass

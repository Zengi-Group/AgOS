"""Configuration for Consulting Engine — Supabase + JWT settings.

All fields have defaults to prevent crash on startup when env vars
are not yet injected (Railway sets env vars after container start).
Actual values come from Railway environment variables.
"""

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # Supabase — defaults prevent crash; actual values from Railway env
    supabase_url: str = ""
    supabase_service_key: str = ""
    supabase_jwt_secret: str = ""

    # Server
    host: str = "0.0.0.0"
    port: int = 8080
    environment: str = "production"

    # CORS
    allowed_origins: list[str] = [
        "http://localhost:5173",
        "https://ag-os.vercel.app",
        "https://turanstandard.kz",
        "https://www.turanstandard.kz",
    ]

    # Feature flags
    # TAXONOMY-M3b (ADR-ANIMAL-01): when True, feeding_model reads
    # animal_category → herd_group mappings via rpc_get_category_mappings
    # instead of the hardcoded CATEGORY_CODE_TO_HERD dict.
    # Flipped True (2026-04-16): snapshot parity 3/3 confirmed.
    # Hardcoded CATEGORY_CODE_TO_HERD stays as fallback (HS-5 additive arch).
    # Override: set TAXONOMY_RPC_READ=false in Railway env to revert.
    taxonomy_rpc_read: bool = True

    model_config = {"env_file": ".env", "env_file_encoding": "utf-8"}


settings = Settings()

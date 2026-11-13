from django.db import connection
from django.http import JsonResponse


def readyz(request):
    """Readiness check used by the CI/CD smoke test. Returns 200 only if the DB answers."""
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
    except Exception:
        return JsonResponse({"status": "error"}, status=503)
    return JsonResponse({"status": "ok"})

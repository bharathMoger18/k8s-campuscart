# campuscart/urls.py
from django.contrib import admin
from django.urls import path, include, re_path
from django.conf import settings
from django.conf.urls.static import static
from django.views.static import serve
from django.http import FileResponse, Http404
from push.views import service_worker
from products.views import product_redirect_view
import os

FRONTEND_DIR = os.path.join(settings.BASE_DIR, 'frontend')

def serve_frontend(request, path=''):
    # Default to index.html for root or unknown paths
    if not path or path == '/':
        path = 'index.html'
    
    file_path = os.path.join(FRONTEND_DIR, path)
    
    # If exact file exists, serve it
    if os.path.isfile(file_path):
        return FileResponse(open(file_path, 'rb'))
    
    # Otherwise serve index.html (SPA fallback)
    index_path = os.path.join(FRONTEND_DIR, 'index.html')
    if os.path.isfile(index_path):
        return FileResponse(open(index_path, 'rb'))
    
    raise Http404(f"File not found: {path}")

urlpatterns = [
    path("admin/", admin.site.urls),
    path("products/<int:pk>/", product_redirect_view, name="product-view"),
    path("api/v1/", include(("campuscart.api_urls", "api"), namespace="v1")),
    path("api/v1/payments/", include("payments.urls")),
    path("sw.js", service_worker, name="service-worker"),
]

# Serve media files
urlpatterns += [
    re_path(r"^media/(?P<path>.*)$", serve, {"document_root": settings.MEDIA_ROOT}),
]

# Serve frontend
urlpatterns += [
    re_path(r"^(?P<path>.*)$", serve_frontend),
]
